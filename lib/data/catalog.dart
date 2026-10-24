import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../cache/disk_cache.dart';
import '../cache/media_cache.dart';
import '../gateway/gateway.dart';
import 'models.dart';
import 'catalog_details.dart';

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
    this.artists = const <ArtistRef>[],
  });

  final List<Track> tracks;
  final List<Album> albums;
  final List<Playlist> playlists;

  /// Derived from the song hits: a query that matches songs also surfaces
  /// their artists, which is what the artists tab lists.
  final List<ArtistRef> artists;

  static const SearchResults empty = SearchResults();

  int get hits =>
      tracks.length + albums.length + playlists.length + artists.length;
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
  Catalog({NeteaseGateway? gateway, DiskCache? cache})
    : gateway = gateway ?? NeteaseGateway(),
      cache = cache ?? DiskCache.shared,
      audioCache = AudioCache(disk: cache);

  final NeteaseGateway gateway;
  final DiskCache cache;
  final AudioCache audioCache;
  final _requests = <String, Future<Object>>{};

  // Private playlists and recommendations must not cross session boundaries.
  String get _scope {
    final cookie = gateway.sessionCookie;
    return cookie == null
        ? 'guest'
        : sha256.convert(utf8.encode(cookie)).toString();
  }

  Future<T> _cached<T extends Object>(
    String key,
    Duration ttl,
    T Function(Map<String, dynamic>) decode,
    Map<String, dynamic> Function(T) encode,
    Future<T> Function() fetch,
  ) async {
    final pending = _requests[key];
    if (pending != null) return await pending as T;
    final future = () async {
      final saved = await cache.readJson(key);
      T? previous;
      if (saved != null) {
        try {
          previous = decode(saved.data);
        } catch (_) {
          await cache.remove(CacheBucket.data, key, extension: 'json');
        }
        if (previous != null && saved.fresh(ttl)) return previous;
      }
      try {
        final result = await fetch();
        await cache.writeJson(key, encode(result));
        return result;
      } catch (_) {
        _online = false;
        if (previous != null) return previous;
        rethrow;
      }
    }();
    _requests[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_requests[key], future)) _requests.remove(key);
    }
  }

  Future<void> invalidatePlaylist(String id) =>
      cache.expireJson('playlist:$_scope:$id');

  Future<void> invalidateCollections(int uid) =>
      cache.expireJson('collections:$_scope:$uid');

  Future<List<Track>> refreshPlaylist(String id) async {
    await invalidatePlaylist(id);
    return playlistTracks(id);
  }

  Future<void> invalidateHome({int? userId}) =>
      cache.expireJson('home:$_scope:${userId ?? 0}');

  Future<void> invalidateLyrics(String trackId) =>
      cache.expireJson('lyrics:$trackId');

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
    try {
      _home = await _cached(
        'home:$_scope:${userId ?? 0}',
        const Duration(minutes: 20),
        _decodeHome,
        _encodeHome,
        () async {
          final feed = await _loadHome(userId: userId);
          if (feed == null) throw StateError('Home unavailable');
          return feed;
        },
      );
      _homeError = null;
      return _home;
    } catch (_) {
      _homeError = '曲库加载失败，请检查网络后重试。';
      return _home = null;
    }
  }

  Future<HomeFeed?> _loadHome({int? userId}) async {
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
          gateway.searchArtists(query, limit: 10),
        ],
      );
      final List<GatewaySong> songs =
          results[0] as List<GatewaySong>? ?? const <GatewaySong>[];
      final List<GatewayAlbum> albumHits =
          results[1] as List<GatewayAlbum>? ?? const <GatewayAlbum>[];
      final List<GatewayArtist> artistHits =
          results[3] as List<GatewayArtist>? ?? const <GatewayArtist>[];
      final List<GatewayPlaylist> playlistHits =
          results[2] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
      _online = true;
      final List<Track> tracks = songs.map<Track>(trackFromSong).toList();
      final Map<int, ArtistRef> artistsById = <int, ArtistRef>{};
      for (final Track track in tracks) {
        for (final ArtistRef artist in track.artists) {
          if (artist.id > 0) artistsById[artist.id] = artist;
        }
      }
      return SearchResults(
        tracks: tracks,
        albums: albumHits.map<Album>(albumFromGateway).toList(),
        playlists: playlistHits.map<Playlist>(playlistFromGateway).toList(),
        artists: <ArtistRef>[
          for (final GatewayArtist artist in artistHits)
            ArtistRef(
              id: artist.id,
              name: artist.name,
              coverUrl: artist.coverUrl,
            ),
          ...artistsById.values.where(
            (ArtistRef artist) => !artistHits.any(
              (GatewayArtist hit) => hit.id == artist.id,
            ),
          ),
        ],
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  /// Reuses recent snapshots; expired snapshots remain available offline.
  Future<List<Track>> playlistTracks(String playlistId) => _cached(
    'playlist:$_scope:$playlistId',
    const Duration(minutes: 10),
    (json) => _decodeTracks(json['tracks']),
    (tracks) => {'tracks': tracks.map((track) => track.toJson()).toList()},
    () => _playlistTracks(playlistId),
  );

  /// Fetches the complete playlist in stable 500-song pages.
  Future<List<Track>> _playlistTracks(String playlistId) async {
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
  Future<UserCollections> userCollections(int uid) => uid <= 0
      ? Future.value(UserCollections.empty)
      : _cached(
          'collections:$_scope:$uid',
          const Duration(minutes: 5),
          _decodeCollections,
          _encodeCollections,
          () => _userCollections(uid),
        );

  Future<UserCollections> _userCollections(int uid) async {
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
    return (await albumDetails(albumId)).tracks;
  }

  Future<AlbumDetails> albumDetails(int albumId, {bool force = false}) async {
    if (albumId <= 0) throw ArgumentError.value(albumId, 'albumId');
    final key = 'album-detail:$albumId';
    if (force) await cache.expireJson(key);
    return _cached(
      key,
      const Duration(hours: 1),
      AlbumDetails.fromJson,
      (value) => value.toJson(),
      () async {
        final Map<String, dynamic> body = await gateway.albumDetailRaw(albumId);
        final rawAlbum = body['album'];
        if (rawAlbum is! Map<String, dynamic>) {
          throw StateError('Album metadata unavailable');
        }
        final dynamic songs = body['songs'];
        final List<GatewaySong> parsed = songs is List
            ? songs
                  .whereType<Map<String, dynamic>>()
                  .map<GatewaySong>(GatewaySong.fromJson)
                  .where((GatewaySong song) => song.id > 0)
                  .toList()
            : const <GatewaySong>[];
        _online = true;
        return AlbumDetails(
          album: albumFromGateway(GatewayAlbum.fromJson(rawAlbum)),
          tracks: parsed.map<Track>(trackFromSong).toList(),
          description: rawAlbum['description'] as String? ?? '',
          company: rawAlbum['company'] as String? ?? '',
          publishTime: (rawAlbum['publishTime'] as num?)?.toInt(),
        );
      },
    );
  }

  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async {
    if (seed.id <= 0) throw ArgumentError.value(seed.id, 'artistId');
    final key = 'artist-detail:${seed.id}';
    if (force) await cache.expireJson(key);
    return _cached(
      key,
      const Duration(minutes: 30),
      ArtistDetails.fromJson,
      (value) => value.toJson(),
      () async {
        final results = await Future.wait<Object>([
          gateway.artistTopSongs(seed.id),
          gateway.artistDetail(seed.id).catchError((_) => <String, dynamic>{}),
        ]);
        final tracks = (results[0] as List<GatewaySong>)
            .where((song) => song.id > 0)
            .map(trackFromSong)
            .toList();
        final payload = results[1] as Map<String, dynamic>;
        final data = payload['data'];
        final raw = data is Map<String, dynamic>
            ? data['artist']
            : payload['artist'];
        final metadata = raw is Map<String, dynamic>
            ? raw
            : <String, dynamic>{};
        final artist = GatewayArtist.fromJson(metadata);
        _online = true;
        return ArtistDetails(
          artist: ArtistRef(
            id: seed.id,
            name: artist.name.isEmpty ? seed.name : artist.name,
            coverUrl: artist.coverUrl ?? seed.coverUrl,
          ),
          tracks: tracks,
          description: metadata['briefDesc'] as String? ?? '',
          musicCount: (metadata['musicSize'] as num?)?.toInt() ?? 0,
          albumCount: (metadata['albumSize'] as num?)?.toInt() ?? 0,
        );
      },
    );
  }

  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async {
    if (id <= 0 || offset < 0) throw ArgumentError('Invalid artist album page');
    final key = 'artist-albums:$id:$offset';
    if (force) await cache.expireJson(key);
    return _cached(
      key,
      const Duration(minutes: 15),
      ArtistAlbumPage.fromJson,
      (value) => value.toJson(),
      () async {
        final payload = await gateway.artistAlbums(id, offset: offset);
        final raw = payload['hotAlbums'];
        final albums = raw is List
            ? [
                for (final album in raw)
                  if (album is Map<String, dynamic>)
                    albumFromGateway(GatewayAlbum.fromJson(album)),
              ]
            : <Album>[];
        _online = true;
        return ArtistAlbumPage(
          albums: albums
              .where((album) => (int.tryParse(album.id) ?? 0) > 0)
              .toList(),
          more: payload['more'] == true && albums.isNotEmpty,
          receivedCount: raw is List ? raw.length : 0,
        );
      },
    );
  }

  Future<List<Track>> artistSongs(int id, {bool force = false}) async {
    if (id <= 0) throw ArgumentError.value(id, 'artistId');
    final key = 'artist-songs:$id';
    if (force) await cache.expireJson(key);
    return _cached(
      key,
      const Duration(minutes: 30),
      (json) => _decodeTracks(json['tracks']),
      (tracks) => <String, dynamic>{
        'tracks': tracks.map((track) => track.toJson()).toList(),
      },
      () async {
        const int limit = 100;
        var offset = 0;
        var more = true;
        final List<Track> tracks = <Track>[];
        final Set<String> ids = <String>{};
        while (more) {
          final payload = await gateway.artistSongs(
            id,
            limit: limit,
            offset: offset,
          );
          final dynamic raw = payload['songs'];
          final List<dynamic> page = raw is List ? raw : const <dynamic>[];
          for (final item in page.whereType<Map<String, dynamic>>()) {
            final song = GatewaySong.fromJson(item);
            if (song.id > 0) {
              final track = trackFromSong(song);
              if (ids.add(track.id)) tracks.add(track);
            }
          }
          offset += page.length;
          more = payload['more'] == true && page.isNotEmpty;
        }
        _online = true;
        return tracks;
      },
    );
  }

  /// Playback URL for a track, or null when the gateway has none (VIP /
  /// region lock / offline).
  Future<String?> audioUrlFor(Track track) async {
    final int id = int.tryParse(track.id) ?? 0;
    if (id <= 0) return null;
    final cached = await audioCache.find(track.id);
    if (cached != null) return cached.uri.toString();
    try {
      final GatewaySongUrl? url = await gateway.songUrl(id);
      _online = url != null;
      final raw = url?.url;
      final source = raw?.startsWith('http://') == true
          ? raw!.replaceFirst('http://', 'https://')
          : raw;
      if (source != null && source.isNotEmpty) {
        unawaited(audioCache.store(track.id, source, format: url?.type));
      }
      return source;
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<GatewayLyrics?> lyricsFor(Track track) => _cached(
    'lyrics:${track.id}',
    const Duration(days: 7),
    (json) => GatewayLyrics(
      lrc: json['lrc'] as String?,
      yrc: json['yrc'] as String?,
      tlyric: json['tlyric'] as String?,
      ytlrc: json['ytlrc'] as String?,
      pureMusic: json['pureMusic'] as bool? ?? false,
    ),
    (lyrics) => {
      'lrc': lyrics.lrc,
      'yrc': lyrics.yrc,
      'tlyric': lyrics.tlyric,
      'ytlrc': lyrics.ytlrc,
      'pureMusic': lyrics.pureMusic,
    },
    () async {
      final lyrics = await _lyricsFor(track);
      if (lyrics == null) throw StateError('Lyrics unavailable');
      return lyrics;
    },
  );

  Future<GatewayLyrics?> _lyricsFor(Track track) async {
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

  static List<Track> _decodeTracks(dynamic raw) => (raw as List)
      .map((item) => Track.fromJson(item as Map<String, dynamic>))
      .toList();
  static List<Playlist> _decodePlaylists(dynamic raw) => (raw as List)
      .map((item) => Playlist.fromJson(item as Map<String, dynamic>))
      .toList();
  static UserCollections _decodeCollections(Map<String, dynamic> json) =>
      UserCollections(
        liked: json['liked'] == null
            ? null
            : Playlist.fromJson(json['liked'] as Map<String, dynamic>),
        created: _decodePlaylists(json['created']),
        subscribed: _decodePlaylists(json['subscribed']),
      );
  static Map<String, dynamic> _encodeCollections(UserCollections value) => {
    'liked': value.liked?.toJson(),
    'created': value.created.map((p) => p.toJson()).toList(),
    'subscribed': value.subscribed.map((p) => p.toJson()).toList(),
  };
  static HomeFeed _decodeHome(Map<String, dynamic> json) => HomeFeed(
    featured: json['featured'] == null
        ? null
        : Album.fromJson(json['featured'] as Map<String, dynamic>),
    recommended: _decodePlaylists(json['recommended']),
    featuredTracks: _decodeTracks(json['featuredTracks']),
    quick: _decodeTracks(json['quick']),
    playlists: _decodePlaylists(json['playlists']),
    albums: (json['albums'] as List)
        .map((a) => Album.fromJson(a as Map<String, dynamic>))
        .toList(),
  );
  static Map<String, dynamic> _encodeHome(HomeFeed value) => {
    'featured': value.featured?.toJson(),
    'recommended': value.recommended.map((p) => p.toJson()).toList(),
    'featuredTracks': value.featuredTracks.map((t) => t.toJson()).toList(),
    'quick': value.quick.map((t) => t.toJson()).toList(),
    'playlists': value.playlists.map((p) => p.toJson()).toList(),
    'albums': value.albums.map((a) => a.toJson()).toList(),
  };

  static int _seedFrom(int id) => id.hashCode & 0x7fffffff;

  static int _accentFrom(int id) => id.abs() % 3;

  static Track trackFromSong(GatewaySong song) => Track(
    id: song.id.toString(),
    title: song.title,
    artist: song.artistLine,
    artists: song.artistDetails.map(artistFromGateway).toList(),
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
    artists: song.artistDetails.map(artistFromGateway).toList(),
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
      artists: album.artists.map(artistFromGateway).toList(),
      year: year,
      coverSeed: _seedFrom(album.id),
      note: album.trackCount > 0 ? '${album.trackCount} 首曲目' : '',
      accent: _accentFrom(album.id),
      trackCount: album.trackCount > 0 ? album.trackCount : null,
      coverUrl: album.coverUrl,
      releaseType: album.releaseType,
      subType: album.subType,
    );
  }

  static ArtistRef artistFromGateway(GatewayArtist artist) =>
      ArtistRef(id: artist.id, name: artist.name, coverUrl: artist.coverUrl);

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
