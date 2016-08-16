module music;

import std.path,
       std.file,
       std.stdio,
       std.range,
       std.variant,
       std.algorithm,
       std.container.dlist;

import dscord.core,
       dscord.voice.client,
       dscord.voice.youtubedl,
       dscord.util.process;

import dcad.types : DCAFile;

/**
  TODO:
    - Support saving the current song state
    - Volume or live muxing
*/

alias PlaylistItemDList = DList!PlaylistItem;

struct PlaylistItem {
  MusicPlugin plugin;

  string id;
  string name;
  string url;

  User addedBy;
  DCAPlayable _playable;

  this(MusicPlugin plugin, VibeJSON song, User author) {
    this.plugin = plugin;
    this.id = song["id"].get!string;
    this.name = song["title"].get!string;
    this.url = song["webpage_url"].get!string;
    this.addedBy = author;
  }

  @property void playable(DCAPlayable playable) {
    this._playable = playable;
  }

  @property DCAPlayable playable() {
    if (!this._playable) {
      this._playable = new DCAPlayable(this.plugin.getFromCache(this.id));
    }
    return this._playable;
  }
}

class MusicPlaylist : PlaylistProvider {
  Channel channel;
  PlaylistItemDList items;
  PlaylistItem* current;

  this(Channel channel) {
    this.channel = channel;
  }

  void add(PlaylistItem item) {
    this.items.insertBack(item);
  }

  void remove(PlaylistItem item) {
    this.items.linearRemove(find(this.items[], item).take(1));
  }

  void clear() {
    this.items.remove(this.items[]);
  }

  size_t length() {
    return walkLength(this.items[]);
  }

  bool hasNext() {
    return (this.length() > 0);
  }

  Playable getNext() {
    this.current = &this.items.front();
    this.channel.sendMessagef("Now playing: %s", this.current.name);

    this.items.removeFront();
    return this.current.playable;
  }
}

alias VoiceClientMap = ModelMap!(Snowflake, VoiceClient);
alias MusicPlaylistMap = ModelMap!(Snowflake, MusicPlaylist);

class MusicPlugin : Plugin {
  @Synced VoiceClientMap voiceClients;
  @Synced MusicPlaylistMap playlists;

  // Config options
  bool cacheFiles = true;
  string cacheDirectory;

  this() {
    this.voiceClients = new VoiceClientMap;
    this.playlists = new MusicPlaylistMap;

    auto opts = new PluginOptions;
    opts.useStorage = true;
    opts.useConfig = true;
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

    string prefix = this.config.has("prefix") ? this.config["prefix"].get!string : "music";
    int level = this.config.has("level") ? this.config["level"].get!int : 0;

    foreach (command; this.commands.values) {
      command.setGroup(prefix);
      command.level = level;
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
    this.stateUnload!MusicPlugin(this.state);
    super.unload(bot);
  }

  const string cachePathFor(string hash) {
    return this.cacheDirectory ~ dirSeparator ~ hash ~ ".dca";
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

    foreach (command; this.commands.values) {
      table.add(command.trigger, command.description);
    }

    MessageBuffer buffer = new MessageBuffer;
    table.appendToBuffer(buffer);
    e.msg.reply(buffer);
  }

  @Command("join")
  @CommandDescription("Join the current voice channel")
  void commandJoin(CommandEvent e) {
    auto state = e.msg.guild.voiceStates.pick(s => s.userID == e.msg.author.id);
    if (!state) {
      e.msg.reply("You need to be connected to voice to have the bot join.");
      return;
    }

    if (this.voiceClients.has(e.msg.guild.id)) {
      if (this.voiceClients[e.msg.guild.id].channel == state.channel) {
        e.msg.reply("Umm... I'm already here bub.");
        return;
      }
      this.voiceClients[e.msg.guild.id].disconnect();
    }

    auto vc = state.channel.joinVoice();
    if (!vc.connect()) {
      e.msg.reply("Huh. Looks like I couldn't connect to voice.");
      return;
    }

    this.voiceClients[e.msg.guild.id] = vc;
  }

  @Command("leave")
  @CommandDescription("Leave the current voice channel")
  void commandLeave(CommandEvent e) {
    if (this.voiceClients.has(e.msg.guild.id)) {
      this.voiceClients[e.msg.guild.id].disconnect(false);
      this.voiceClients.remove(e.msg.guild.id);
      e.msg.reply("Bye now.");
    } else {
      e.msg.reply("I'm not even connected to voice 'round these parts.");
    }

    // If we have a playlist, clear it
    auto playlist = this.getPlaylist(e.msg.channel, false);
    playlist.clear();
  }

  @Command("play")
  @CommandDescription("Play a URL")
  void commandPlay(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("I can't play stuff if I'm not connected to voice.");
      return;
    }

    if (e.args.length < 1) {
      e.msg.reply("Must specify a URL to play.");
      return;
    }

    YoutubeDL.getInfoAsync(e.args[0], (song) {
      this.addFromInfo(client, e.msg, song);
    }, (count) {
      e.msg.replyf(":ok_hand: added %s songs.", count);
    });
  }

  ulong addFromInfo(VoiceClient client, Message msg, VibeJSON song) {
    auto item = PlaylistItem(this, song, msg.author);
    auto playlist = this.getPlaylist(msg.channel);

    // Try to grab file from cache, otherwise download directly (and then cache)
    DCAFile file = this.getFromCache(item.id);
    if (!file) {
      file = YoutubeDL.download(item.url);
      this.saveToCache(file, item.id);
    }

    // If this is the first item to be played, or if we have file caching off,
    //   we set the items playable now. Otherwise it will be lazily loaded from
    //   disk when it needs to be played.
    if (!playlist.length || !this.cacheFiles) {
      item.playable = new DCAPlayable(file);
    }

    playlist.add(item);

    // Play the playlist
    if (!client.playing) {
      client.play(new Playlist(playlist));
    }

    return playlist.length;
  }

  @Command("pause")
  @CommandDescription("Pause the playback")
  void commandPause(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("Can't pause if I'm not playing anything.");
      return;
    }

    if (client.paused) {
      e.msg.reply("I'm already paused ya silly goose.");
      return;
    }

    client.pause();
  }

  @Command("skip")
  @CommandDescription("Skip the current song")
  void commandSkip(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("Can't pause if I'm not playing anything.");
      return;
    }

    auto playlist = this.getPlaylist(e.msg.channel, false);

    if (!client.playing || !playlist) {
      e.msg.reply("I'm not playing anything yet bruh.");
      return;
    }

    auto playable = cast(Playlist)(client.playable);
    playable.next();
  }

  @Command("resume")
  @CommandDescription("Resume the playback")
  void commandResume(CommandEvent e) {
    auto client = this.voiceClients.get(e.msg.guild.id, null);
    if (!client) {
      e.msg.reply("Can't resume if I'm not playing anything.");
      return;
    }

    if (!client.paused) {
      e.msg.reply("I'm already playing stuff ya silly goose.");
      return;
    }

    client.resume();
    e.msg.reply("Music resumed.");
  }

  @Command("queue")
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

    MessageBuffer buffer = new MessageBuffer(false);
    size_t index;
    bool empty;

    foreach (item; playlist.items) {
      index++;
      empty = buffer.appendf("%s. %s (added by %s)", index, item.name, item.addedBy.username);
      if (!empty) {
        buffer.popBack();
        buffer.appendf("and %s more...", playlist.length - index);
        break;
      }
    }

    e.msg.reply(buffer);
  }

  @Command("nowplaying")
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
      playlist.current.addedBy.username,
      playlist.current.url);
  }

  @Command("test")
  void commandTest(CommandEvent e) {
    e.msg.replyf("wtf");
  }
}

extern (C) Plugin create() {
  return new MusicPlugin;
}
