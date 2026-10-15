import '../gateway/gateway.dart';
import 'models.dart';

/// Music returned by the gateway.
class HomeFeed {
  const HomeFeed({
    this.featured,
    this.recommended = const [],
    required this.featuredTracks,
    required this.quick,
    required this.playlists,
    required this.albums,
  });

  final Album? featured;
  final List<Playlist> recommended;
  final List<Track> featuredTracks;
  final List<Track> quick;
  final List<Playlist> playlists;
  final List<Album> albums;

  bool get isEmpty =>
      recommended.isEmpty &&
      featured == null &&
      quick.isEmpty &&
      playlists.isEmpty &&
      albums.isEmpty;
}

class SearchResults {
  const SearchResults({
    this.tracks = const <Track>[],
    this.albums = const <Album>[],
    this.playlists = const <Playlist>[],
  });

  final List<Track> tracks;
  final List<Album> albums;
  final List<Playlist> playlists;

  static const SearchResults empty = SearchResults();

  int get hits => tracks.length + albums.length + playlists.length;
}

/// A signed-in user's own collections, split the way the profile page shows
/// them: the personal liked-songs collection, playlists they created, and
/// playlists they subscribed to.
class UserCollections {
  const UserCollections({
    this.liked,
    this.created = const <Playlist>[],
    this.subscribed = const <Playlist>[],
  });

  /// The "喜欢的音乐" collection (NetEase `specialType = 5`), when present.
  final Playlist? liked;
  final List<Playlist> created;
  final List<Playlist> subscribed;

  static const UserCollections empty = UserCollections();
}

/// Gateway-backed catalogue. Failed requests never create fabricated music.
class Catalog {
  Catalog({NeteaseGateway? gateway}) : gateway = gateway ?? NeteaseGateway();

  final NeteaseGateway gateway;

  /// Whether the last gateway interaction succeeded.
  bool get online => _online;
  bool _online = false;
  String? _homeError;
  String? get homeError => _homeError;

  HomeFeed? _home;

  /// The loaded home feed, or null until [loadHome] has run.
  HomeFeed? get home => _home;

  Future<HomeFeed?> loadHome({int? userId}) async {
    _homeError = null;
    Object? firstFailure;
    Future<T?> optional<T>(Future<T> request) async {
      try {
        return await request;
      } catch (error) {
        firstFailure ??= error;
        return null;
      }
    }

    final results = await Future.wait<Object?>(<Future<Object?>>[
      optional(gateway.topPlaylists(limit: 12)),
      if (userId != null && userId > 0)
        optional(gateway.userPlaylists(userId, limit: 30)),
      if (userId != null && userId > 0)
        optional(gateway.dailyRecommendedSongs()),
      if (userId != null && userId > 0)
        optional(gateway.dailyRecommendedPlaylists()),
      optional(gateway.personalizedPlaylists()),
    ]);
    final top =
        results[0] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final signedIn = userId != null && userId > 0;
    final userPlaylists = signedIn
        ? results[1] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[]
        : const <GatewayPlaylist>[];
    final dailySongs = signedIn
        ? results[2] as List<GatewaySong>? ?? const <GatewaySong>[]
        : const <GatewaySong>[];
    final dailyPlaylists = signedIn
        ? results[3] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[]
        : const <GatewayPlaylist>[];
    final personalized =
        results[signedIn ? 4 : 1] as List<GatewayPlaylist>? ?? const [];
    final recommended = <int, GatewayPlaylist>{};
    for (final playlist in [...dailyPlaylists, ...personalized]) {
      recommended.putIfAbsent(playlist.id, () => playlist);
    }

    List<Track> quick = dailySongs.take(8).map(trackFromSong).toList();
    if (quick.isEmpty && top.isNotEmpty) {
      try {
        quick = (await playlistTracks(
          top.first.id.toString(),
        )).take(8).toList();
      } catch (error) {
        firstFailure ??= error;
      }
    }

    final uniquePlaylists = <int, GatewayPlaylist>{};
    for (final playlist in <GatewayPlaylist>[
      ...userPlaylists,
      ...recommended.values,
      ...top,
    ]) {
      if (playlist.id > 0) {
        uniquePlaylists.putIfAbsent(playlist.id, () => playlist);
      }
    }

    final albumSongs = <int, GatewaySong>{};
    for (final song in dailySongs) {
      if (song.albumId > 0) albumSongs.putIfAbsent(song.albumId, () => song);
    }
    Album? featured;
    if (dailySongs.isNotEmpty && dailySongs.first.albumId > 0) {
      featured = albumFromSong(dailySongs.first);
    } else if (quick.isNotEmpty && quick.first.albumId > 0) {
      final track = quick.first;
      featured = Album(
        id: track.albumId.toString(),
        title: track.album,
        artist: track.artist,
        year: '',
        coverSeed: track.coverSeed,
        note: '',
        coverUrl: track.coverUrl,
      );
    }

    final feed = HomeFeed(
      recommended: (recommended.isEmpty ? top : recommended.values)
          .take(8)
          .map(playlistFromGateway)
          .toList(),
      featured: featured,
      featuredTracks: dailySongs
          .where((song) => song.albumId == dailySongs.firstOrNull?.albumId)
          .take(8)
          .map(trackFromSong)
          .toList(),
      quick: quick,
      playlists: uniquePlaylists.values
          .take(12)
          .map(playlistFromGateway)
          .toList(),
      albums: albumSongs.values.take(8).map(albumFromSong).toList(),
    );
    _online = firstFailure == null || !feed.isEmpty;
    if (feed.isEmpty && firstFailure != null) {
      _homeError = '曲库加载失败，请检查网络后重试。';
      _home = null;
    } else {
      if (feed.isEmpty) _homeError = '当前没有可展示的音乐。';
      _home = feed;
    }
    return _home;
  }

  /// Search the live catalogue. Errors propagate to the search view.
  Future<SearchResults> search(String rawQuery) async {
    final String query = rawQuery.trim();
    if (query.isEmpty) return SearchResults.empty;
    try {
      final List<Object?> results = await Future.wait<Object?>(
        <Future<Object?>>[
          // cloudsearch carries album.picUrl; the legacy /search payload only
          // exposes a picId, which leaves track covers unrenderable.
          gateway.search(query, limit: 20, useCloudSearch: true),
          gateway.searchAlbums(query, limit: 10),
          gateway.searchPlaylists(query, limit: 10),
        ],
      );
      final List<GatewaySong> songs =
          results[0] as List<GatewaySong>? ?? const <GatewaySong>[];
      final List<GatewayAlbum> albumHits =
          results[1] as List<GatewayAlbum>? ?? const <GatewayAlbum>[];
      final List<GatewayPlaylist> playlistHits =
          results[2] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
      _online = true;
      return SearchResults(
        tracks: songs.map<Track>(trackFromSong).toList(),
        albums: albumHits.map<Album>(albumFromGateway).toList(),
        playlists: playlistHits.map<Playlist>(playlistFromGateway).toList(),
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  /// Fetches the complete playlist in stable 500-song pages.
  Future<List<Track>> playlistTracks(String playlistId) async {
    final int id = int.tryParse(playlistId) ?? 0;
    if (id <= 0) throw ArgumentError.value(playlistId, 'playlistId');
    try {
      final Map<String, dynamic> body = await gateway.playlistDetail(id);
      final dynamic rawPlaylist = body['playlist'];
      if (rawPlaylist is! Map<String, dynamic>) throw StateError('歌单数据不可用。');
      final GatewayPlaylist playlist = GatewayPlaylist.fromJson(rawPlaylist);
      final Map<int, GatewaySong> byId = <int, GatewaySong>{};
      for (int offset = 0; offset < playlist.trackIds.length; offset += 500) {
        final int end = (offset + 500).clamp(0, playlist.trackIds.length);
        final songs = await gateway.songDetails(
          playlist.trackIds.sublist(offset, end),
        );
        for (final song in songs) {
          byId[song.id] = song;
        }
      }
      _online = true;
      return <Track>[
        for (final songId in playlist.trackIds)
          if (byId[songId] != null) trackFromSong(byId[songId]!),
      ];
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  /// The signed-in user's own collections: liked songs, created playlists,
  /// subscribed playlists. Errors propagate to the profile view.
  Future<UserCollections> userCollections(int uid) async {
    if (uid <= 0) return UserCollections.empty;
    try {
      final List<GatewayPlaylist> raw = await gateway.userPlaylists(
        uid,
        limit: 1000,
      );
      _online = true;
      Playlist? liked;
      final List<Playlist> created = <Playlist>[];
      final List<Playlist> subscribed = <Playlist>[];
      for (final GatewayPlaylist p in raw) {
        final Playlist playlist = playlistFromGateway(p);
        // The personal liked collection also shows up as "created"; pull it
        // out so the profile can label and count it on its own (mirrors the
        // reference: specialType 5, name fallback for legacy payloads).
        if (p.specialType == 5 || (p.created && p.name.endsWith('喜欢的音乐'))) {
          liked ??= playlist;
        } else if (p.created) {
          created.add(playlist);
        } else {
          subscribed.add(playlist);
        }
      }
      return UserCollections(
        liked: liked,
        created: created,
        subscribed: subscribed,
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<List<Track>> albumTracks(int albumId) async {
    if (albumId <= 0) throw ArgumentError.value(albumId, 'albumId');
    try {
      final Map<String, dynamic> body = await gateway.albumDetailRaw(albumId);
      final dynamic songs = body['songs'];
      final List<GatewaySong> parsed = songs is List
          ? songs
                .whereType<Map<String, dynamic>>()
                .map<GatewaySong>(GatewaySong.fromJson)
                .where((GatewaySong song) => song.id > 0)
                .toList()
          : const <GatewaySong>[];
      _online = true;
      return parsed.map<Track>(trackFromSong).toList();
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  /// Playback URL for a track, or null when the gateway has none (VIP /
  /// region lock / offline).
  Future<String?> audioUrlFor(Track track) async {
    final int id = int.tryParse(track.id) ?? 0;
    if (id <= 0) return null;
    try {
      final GatewaySongUrl? url = await gateway.songUrl(id);
      _online = url != null;
      final raw = url?.url;
      return raw?.startsWith('http://') == true
          ? raw!.replaceFirst('http://', 'https://')
          : raw;
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<GatewayLyrics?> lyricsFor(Track track) async {
    final int id = int.tryParse(track.id) ?? 0;
    if (id <= 0) return null;
    try {
      final GatewayLyrics lyrics = await gateway.preferredLyrics(id);
      _online = true;
      return lyrics;
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  // -- mapping --------------------------------------------------------------

  static int _seedFrom(int id) => id.hashCode & 0x7fffffff;

  static int _accentFrom(int id) => id.abs() % 3;

  static Track trackFromSong(GatewaySong song) => Track(
    id: song.id.toString(),
    title: song.title,
    artist: song.artistLine,
    album: song.albumName,
    albumId: song.albumId,
    translatedTitle: song.translatedTitle,
    duration: song.duration,
    coverSeed: _seedFrom(song.id),
    accent: _accentFrom(song.id),
    coverUrl: song.coverUrl,
  );

  static Album albumFromSong(GatewaySong song) => Album(
    id: song.albumId.toString(),
    title: song.albumName,
    artist: song.artistLine,
    year: '',
    coverSeed: _seedFrom(song.albumId),
    note: '',
    coverUrl: song.coverUrl,
  );

  static Album albumFromGateway(GatewayAlbum album) {
    final String year = album.publishTime != null && album.publishTime! > 0
        ? DateTime.fromMillisecondsSinceEpoch(
            album.publishTime!,
          ).year.toString()
        : '';
    return Album(
      id: album.id.toString(),
      title: album.title,
      artist: album.artist,
      year: year,
      coverSeed: _seedFrom(album.id),
      note: album.trackCount > 0 ? '${album.trackCount} 首曲目' : '',
      accent: _accentFrom(album.id),
      trackCount: album.trackCount > 0 ? album.trackCount : null,
      coverUrl: album.coverUrl,
    );
  }

  static Playlist playlistFromGateway(GatewayPlaylist playlist) => Playlist(
    id: playlist.id.toString(),
    name: playlist.name,
    trackIds: playlist.trackIds.map<String>((int id) => id.toString()).toList(),
    coverSeed: _seedFrom(playlist.id),
    description: playlist.description,
    coverUrl: playlist.coverUrl,
    trackCount: playlist.trackCount,
  );
}
