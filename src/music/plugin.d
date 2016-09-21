module music.plugin;

import std.conv,
       std.path,
       std.file,
       std.stdio,
       std.array,
       std.format,
       std.variant,
       std.algorithm;

import vibe.core.core;

import dscord.core,
       dscord.voice.client,
       dscord.voice.youtubedl,
       dscord.util.process,
       dscord.util.queue;

import dcad.types : DCAFile;

import music.playlist;

alias VoiceClientMap = ModelMap!(Snowflake, VoiceClient);

class Download {
  VoiceClient client;
  Message msg;
  VibeJSON song;

  this(VoiceClient client, Message msg, VibeJSON song) {
    this.client = client;
    this.msg = msg;
    this.song = song;
  }
}

class MusicPlugin : Plugin {
  @Synced VoiceClientMap voiceClients;
  @Synced MusicPlaylistMap playlists;

  // Config options
  bool cacheFiles = true;
  string cacheDirectory;

  BlockingQueue!Download downloads;
  Task downloader;

  this() {
    this.voiceClients = new VoiceClientMap;
    this.playlists = new MusicPlaylistMap;
    this.downloads = new BlockingQueue!Download;

    auto opts = new PluginOptions;
    opts.useStorage = true;
    opts.useConfig = true;
    opts.useOverrides = true;
    opts.commandGroup = "music";
    super(opts);
  }

  override void load(Bot bot, PluginState state = null) {
    super.load(bot, state);

    this.stateLoad!MusicPlugin(this.state);

    if (this.config.has("cache_files")) {
      this.cacheFiles = this.config["cache_files"].get!bool;
    }

    if (this.config.has("cache_directory")) {
      this.cacheDirectory = this.config["cache_dir"].get!string;
    }

    if (!this.cacheDirectory) {
      this.cacheDirectory = this.storageDirectoryPath ~ dirSeparator ~ "cache";
    }

    // Make sure cache folder exists
    if (this.cacheFiles && !exists(this.cacheDirectory)) {
      mkdirRecurse(this.cacheDirectory);
    }
  }

  override void unload(Bot bot) {
    this.cancelDownloads();
    this.stateUnload!MusicPlugin(this.state);

    /+
      TODO: xd
      auto plists = this.storage.ensureObject("playlists");
      foreach (id, playlist; this.playlists) {
        plists[id.toString()] = playlist.toJSON();
      }
    +/

    super.unload(bot);
  }

  const string cachePathFor(string hash) {
    return this.cacheDirectory ~ dirSeparator ~ hash ~ ".dca";
  }

  void cancelDownloads() {
    this.downloads.clear();
    this.downloader.interrupt();
  }

  DCAFile getFromCache(string hash) {
    if (!this.cacheFiles) return null;

    string path = this.cachePathFor(hash);
    if (exists(path)) {
      return new DCAFile(File(path, "r"));
    } else {
      return null;
    }
  }

  void saveToCache(DCAFile obj, string hash) {
    if (!this.cacheFiles) return;

    string path = this.cachePathFor(hash);
    obj.save(path);
  }

  MusicPlaylist getPlaylist(Channel chan, bool create=true) {
    if (!this.playlists.has(chan.guild.id) && create) {
      this.playlists[chan.guild.id] = new MusicPlaylist(chan);
    }
    return this.playlists.get(chan.guild.id, null);
  }

  @Command("help")
  @CommandDescription("View help about music commands")
  void commandMusic(CommandEvent e) {
    MessageTable table = new MessageTable;

    table.setHeader("Command", "Description");

    foreach (command; this.commands.values) {
      table.add(command.name, command.description);
    }

    e.msg.reply(table);
  }

  @Command("join", "summon")
  @CommandDescription("Join the current voice channel")
  void commandJoin(CommandEvent e) {
    // Find the voice state for the user
    auto state = e.msg.guild.voiceStates.pick(s => s.userID == e.msg.author.id);
    if (!state) {
      e.msg.reply("You need to be connected to voice to have the bot join.");
      return;
    }

    // If we're already connected to voice in this guild (but in a different
    //  channel) we need to disconnect/reconnect, otherwise if we're in the same
    //  channel, we just tell the user they are being silly.
    if (this.voiceClients.has(e.msg.guild.id)) {
      if (this.voiceClients[e.msg.guild.id].channel == state.channel) {
        e.msg.reply("Umm... I'm already here bub.");
        return;
      }
      this.voiceClients[e.msg.guild.id].disconnect();
    }

    // Create a new voice connection
    auto vc = state.channel.joinVoice();
    if (!vc.connect()) {
      e.msg.reply("Huh. Looks like I couldn't connect to voice.");
      return;
    }

    // Track this voice state in our mapping
    this.voiceClients[e.msg.guild.id] = vc;
  }

  @Command("leave")
  @CommandDescription("Leave the current voice channel")
  void commandLeave(CommandEvent e) {
    if (!this.voiceClients.has(e.msg.guild.id)) {
      e.msg.reply("I'm not connected to voice in this server.");
      return;
    }

    // Disconnect the client
    this.voiceClients[e.msg.guild.id].disconnect(false);
    this.voiceClients.remove(e.msg.guild.id);

    // If we have a playlist, clear it
    auto playlist = this.getPlaylist(e.msg.channel, false);
    if (playlist) {
      playlist.clear();
    }

    e.msg.reply("See ya later!");
  }

  @Command("play", "add")
  @CommandDescription("Add a URL to the queue")
  void commandPlay(CommandEvent e) {
    this.log.infof("UMM WHAT?");

    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("I can't play stuff if I'm not connected to voice.");
      return;
    }

    if (e.args.length < 1) {
      e.msg.reply("Must specify a URL to play.");
      return;
    }

    // Make sure the downloader is running
    if (!this.downloader || !this.downloader.running) {
      this.downloads.clear();
      this.downloader = runTask(&this.downloaderTask);
    }

    YoutubeDL.getInfoAsync(e.args[0], (song) {
      if (!this.downloader) return;
      this.downloads.push(new Download(client, e.msg, song));
    }, (count) {
      if (!this.downloader) return;
      e.msg.replyf(":ok_hand: downloading and adding %s songs...", count);
    });
  }

  void downloaderTask() {
    while (true) {
      // If nothing is in the queue, wait for something to be inserted
      if (!this.downloads.size) {
        this.downloads.wait();
      }

      // Grab the next item in the queue
      Download dl = this.downloads.peakFront();

      // Try to grab file from cache, otherwise download directly (and then cache)
      auto item = PlaylistItem(this, dl.song, dl.msg.author.username);
      DCAFile file = this.getFromCache(item.id);
      if (!file) {
        file = YoutubeDL.download(item.url);
        this.saveToCache(file, item.id);
      }

      // If our queue has changed, just throw away this progress
      if (this.downloads.peakFront() != dl) {
        continue;
      }

      // Remove this item
      this.downloads.pop();

      // Otherwise grab the playlist and add the song
      auto playlist = this.getPlaylist(dl.msg.channel);

      // If this is the first item to be played, or if we have file caching off,
      //   we set the items playable now. Otherwise it will be lazily loaded from
      //   disk when it needs to be played.
      if (!playlist.length || !this.cacheFiles) {
        item.playable = new DCAPlayable(file);
      }

      playlist.add(item);

      // Play the playlist
      if (!dl.client.playing) {
        dl.client.play(new Playlist(playlist));
      }
    }
  }

  @Command("pause")
  @CommandDescription("Pause the playback")
  void commandPause(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client || !client.playing) {
      e.msg.reply("Can't pause if I'm not playing anything.");
      return;
    }

    if (client.paused) {
      e.msg.reply("I'm already paused ya silly goose.");
      return;
    }

    client.pause();
  }

  @Command("skip", "next")
  @CommandDescription("Skip the current song")
  void commandSkip(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    auto playlist = this.getPlaylist(e.msg.channel, false);

    if (!client || !client.playing || !playlist) {
      e.msg.reply("Can't pause if I'm not playing anything.");
      return;
    }

    auto playable = cast(Playlist)(client.playable);
    playable.next();
  }

  @Command("resume")
  @CommandDescription("Resume the playback")
  void commandResume(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client || !client.playing) {
      e.msg.reply("Can't resume if I'm not playing anything.");
      return;
    }

    if (!client.paused) {
      e.msg.reply("I'm already playing stuff ya silly goose.");
      return;
    }

    client.resume();
  }

  @Command("queue", "q")
  @CommandDescription("View the current play queue")
  void commandQueue(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("Nothing in the queue.");
      return;
    }

    auto playlist = this.getPlaylist(e.msg.channel, false);
    if (!playlist || !playlist.length) {
      e.msg.reply("Nothing in the queue.");
      return;
    }

    MessageTable table = new MessageTable("  ");
    table.buffer = new MessageBuffer();
    table.setHeader("ID", "Name", "Length", "Added By");

    // On the first pass, just add all the playlist items
    size_t index;
    foreach (item; playlist.items) {
      index++;
      table.add(index.toString,
        (item.name.length < 46 ? item.name : item.name[0..46]), item.formatDuration(), item.addedBy);
    }

    // Sort by index
    table.sort(0, (arg) => arg.to!int);

    // Add a line for padding
    table.buffer.append("");

    // Now try to add to the message buffer, and add a footer if it fails
    index = 0;
    foreach (entry; table.iterEntries()) {
      index++;
      if (!table.buffer.append(table.compileEntry(entry))) {
        table.buffer.popBack();
        table.buffer.appendf("and %s more...", playlist.length - index);
        break;
      }
    }

    e.msg.reply(table.buffer);
  }

  @Command("clear")
  @CommandDescription("Clear the song queue")
  void commandClear(CommandEvent e) {
    auto playlist = this.getPlaylist(e.msg.channel, false);
    if (!playlist || !playlist.length) {
      e.msg.reply("Nothing in the queue.");
      return;
    }

    this.cancelDownloads();
    playlist.clear();
    e.msg.reply("Queue cleared");
  }

  @Command("nowplaying", "np")
  @CommandDescription("View the currently playing song")
  void commandNowPlaying(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("Nothing playing.");
      return;
    }

    auto playlist = this.getPlaylist(e.msg.channel, false);
    if (!playlist || !playlist.current) {
      e.msg.reply("Not playing anything right now");
      return;
    }

    e.msg.replyf("Currently playing: %s (added by %s) [<%s>]",
      playlist.current.name,
      playlist.current.addedBy,
      playlist.current.url);
  }

  @Command("invite")
  @CommandDescription("Get a URL to invite this bot to your server")
  void commandInvite(CommandEvent e) {
    e.msg.replyf("Invite: https://discordapp.com/oauth2/authorize?client_id=%s&scope=bot", this.me.id);
  }

  @Command("shuffle")
  @CommandDescription("Shuffle the current queue")
  void commandShuffle(CommandEvent e) {
    auto playlist = this.getPlaylist(e.msg.channel, false);
    if (!playlist || !playlist.current) {
      e.msg.reply("Not playing anything right now");
      return;
    }

    playlist.shuffle();
    e.msg.replyf(":ok_hand: shuffled dat playlist");
  }
}

extern (C) Plugin create() {
  return new MusicPlugin;
}
