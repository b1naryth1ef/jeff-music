module music.playlist;

import music.plugin;

import dscord.core;

import std.array,
       std.range,
       std.format,
       std.random,
       std.algorithm,
       std.container.dlist;

alias PlaylistItemDList = DList!PlaylistItem;
alias MusicPlaylistMap = ModelMap!(Snowflake, MusicPlaylist);

struct PlaylistItem {
  MusicPlugin plugin;

  string id;
  string name;
  string url;
  uint duration;

  string addedBy;
  DCAPlayable _playable;

  this(MusicPlugin plugin, VibeJSON song, string username="") {
    this.plugin = plugin;
    this.id = song["id"].get!string;
    this.name = song["title"].get!string;
    this.url = song["webpage_url"].get!string;
    this.duration = song["duration"].get!uint;

    if (username != "") {
      this.addedBy = username;
    } else if ("added_by" in song) {
      this.addedBy = song["added_by"].get!string;
    }
  }

  VibeJSON toJSON() {
    return VibeJSON([
      "id": VibeJSON(this.id),
      "title": VibeJSON(this.name),
      "webpage_url": VibeJSON(this.url),
      "duration": VibeJSON(this.duration),
      "added_by": VibeJSON(this.addedBy),
    ]);
  }

  string formatDuration() {
    if (this.duration < 60) {
      return format("00:%2s", this.duration);
    }

    if (this.duration < 3600) {
      return format("%02s:%02s",
        (this.duration / 60),
        (this.duration % 60));
    }

    return format("%02s:%02s:%02s",
        (this.duration / 60 / 60),
        (this.duration / 60) % 60,
        (this.duration % 60));
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

  void shuffle() {
    auto itemsCopy = this.items.array;
    randomShuffle(itemsCopy);
    this.items = PlaylistItemDList(itemsCopy);
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

  VibeJSON toJSON() {
    return VibeJSON(this.items.array.map!((x) => x.toJSON()).array);
  }
}

