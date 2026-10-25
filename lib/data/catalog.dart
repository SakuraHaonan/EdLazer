import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../cache/disk_cache.dart';
import '../cache/media_cache.dart';
import '../gateway/gateway.dart';
import 'billboard.dart';
import 'biliboard.dart';
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
    this.editorialPlaylists = const <Playlist>[],
  });

  final Album? featured;
  final List<Playlist> recommended;
  final List<Track> featuredTracks;
  final List<Track> quick;
  final List<Playlist> playlists;
  final List<Album> albums;
  final List<Playlist> editorialPlaylists;

  bool get isEmpty =>
      recommended.isEmpty &&
      featured == null &&
      quick.isEmpty &&
      playlists.isEmpty &&
      albums.isEmpty &&
      editorialPlaylists.isEmpty;
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
  Catalog({
    NeteaseGateway? gateway,
    DiskCache? cache,
    BiliboardClient? charts,
    BillboardClient? billboard,
  }) : gateway = gateway ?? NeteaseGateway(),
       cache = cache ?? DiskCache.shared,
       charts = charts ?? BiliboardClient(),
       billboard = billboard ?? BillboardClient(),
       audioCache = AudioCache(disk: cache);

  final NeteaseGateway gateway;
  final DiskCache cache;
  final BiliboardClient charts;
  final BillboardClient billboard;
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
      cache.expireJson('playlist-v2:$_scope:$id');

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

    final signedIn = userId != null && userId > 0;
    final results = await Future.wait<Object?>(<Future<Object?>>[
      optional(gateway.topPlaylists(limit: 12)),
      optional(
        signedIn
            ? gateway.userPlaylists(userId, limit: 30)
            : Future<List<GatewayPlaylist>>.value(const <GatewayPlaylist>[]),
      ),
      optional(
        signedIn
            ? gateway.dailyRecommendedSongs()
            : Future<List<GatewaySong>>.value(const <GatewaySong>[]),
      ),
      optional(
        signedIn
            ? gateway.dailyRecommendedPlaylists()
            : Future<List<GatewayPlaylist>>.value(const <GatewayPlaylist>[]),
      ),
      optional(gateway.personalizedPlaylists()),
      optional(
        signedIn
            ? gateway.personalizedNewSongs(limit: 24)
            : Future<List<GatewaySong>>.value(const <GatewaySong>[]),
      ),
      // NetEase's main editorial account. Creator identity, rather than the
      // recommendation endpoint, keeps this shelf editorially sourced.
      optional(gateway.userPlaylists(1463586082, limit: 24)),
    ]);
    final top =
        results[0] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final userPlaylists =
        results[1] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final dailySongs =
        results[2] as List<GatewaySong>? ?? const <GatewaySong>[];
    final dailyPlaylists =
        results[3] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final personalized =
        results[4] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
    final newSongs = results[5] as List<GatewaySong>? ?? const <GatewaySong>[];
    final editorial =
        results[6] as List<GatewayPlaylist>? ?? const <GatewayPlaylist>[];
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
    for (final song in newSongs) {
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
      albums: albumSongs.values.take(12).map(albumFromSong).toList(),
      editorialPlaylists: editorial
          .where((playlist) => playlist.specialType != 5)
          .take(12)
          .map(playlistFromGateway)
          .toList(),
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
            (ArtistRef artist) =>
                !artistHits.any((GatewayArtist hit) => hit.id == artist.id),
          ),
        ],
      );
    } catch (_) {
      _online = false;
      rethrow;
    }
  }

  Future<List<Track>> personalFmTracks() async =>
      (await gateway.personalFm()).map(trackFromSong).toList();

  /// External rankings load independently from the main discovery feed. A
  /// slow chart host must never hold the entire home page hostage.
  Future<List<MusicChart>> discoveryCharts() => _cached(
    'external-charts-v3',
    const Duration(hours: 2),
    (json) => (json['charts'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicChart.fromJson)
        .toList(),
    (value) => <String, Object?>{
      'charts': value.map((chart) => chart.toJson()).toList(),
    },
    () async {
      final loaded = await Future.wait<Object?>(<Future<Object?>>[
        billboard.latestChart().catchError((_) => null),
        charts.latestCharts().catchError((_) => const <MusicChart>[]),
      ]);
      return <MusicChart>[
        if (loaded.first case final MusicChart chart) chart,
        ...(loaded.last as List<MusicChart>),
      ];
    },
  );

  /// NetEase mirrors a handful of established charts and, unlike a scraped
  /// ranking, gives us immediately playable song ids. These are current-only:
  /// the API does not expose a trustworthy issue archive.
  Future<List<MusicChart>> neteaseMirrorCharts() => _cached(
    'netease-mirror-charts-v2',
    const Duration(minutes: 30),
    (json) => (json['charts'] as List? ?? const <Object>[])
        .whereType<Map<String, dynamic>>()
        .map(MusicChart.fromJson)
        .toList(),
    (value) => <String, Object?>{
      'charts': value.map((chart) => chart.toJson()).toList(),
    },
    () async {
      final playlists = await gateway.chartPlaylists();
      final selected = playlists
          .where((playlist) {
            final name = playlist.name.toLowerCase();
            return name.contains('uk排行榜') ||
                name.contains('beatport') ||
                name.contains('oricon') ||
                name.contains('nrj');
          })
          .take(5);
      final loaded = await Future.wait<MusicChart?>([
        for (final playlist in selected)
          _neteaseChart(playlist).catchError((_) => null),
      ]);
      return loaded.whereType<MusicChart>().toList();
    },
  );

  Future<MusicChart?> _neteaseChart(GatewayPlaylist playlist) async {
    // Keep the complete source ranking. Several mirrored charts are Top 100
    // lists; the old 20-song cap made every board look artificially identical.
    final body = await gateway.playlistTracks(playlist.id);
    final rawSongs = body['songs'];
    if (rawSongs is! List) return null;
    final songs = rawSongs
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final nested = item['song'] ?? item['data'];
          return GatewaySong.fromJson(
            nested is Map<String, dynamic> ? nested : item,
          );
        })
        .where((song) => song.id > 0 && song.title.isNotEmpty)
        .toList();
    if (songs.isEmpty) return null;
    return MusicChart(
      id: 'netease:${playlist.id}',
      title: playlist.name,
      source: '网易云镜像',
      issueLabel: '当前榜',
      entries: <ChartEntry>[
        for (var index = 0; index < songs.length; index++)
          ChartEntry(
            rank: index + 1,
            title: songs[index].title,
            artist: songs[index].artistLine,
            coverUrl: songs[index].coverUrl,
            track: trackFromSong(songs[index]),
          ),
      ],
      accent: 0xFFE94B64,
      providerKey: 'netease:${playlist.id}',
      logoUrl: playlist.coverUrl,
    );
  }

  Future<MusicChart> chartIssue(MusicChart chart, ChartIssue issue) => _cached(
    'chart-issue-v2:${chart.providerKey}:${issue.id}',
    const Duration(hours: 6),
    MusicChart.fromJson,
    (value) => value.toJson(),
    () => charts.chartForIssue(chart, issue),
  );

  Future<List<Track>> heartModeTracks(Playlist liked) async {
    final int playlistId = int.tryParse(liked.id) ?? 0;
    if (playlistId <= 0) return const <Track>[];
    final List<Track> likedTracks = await playlistTracks(liked.id);
    if (likedTracks.isEmpty) return const <Track>[];
    final int songId = int.tryParse(likedTracks.first.id) ?? 0;
    if (songId <= 0) return likedTracks;
    final generated = await gateway.intelligenceList(
      songId: songId,
      playlistId: playlistId,
      count: 30,
    );
    return generated.isEmpty
        ? likedTracks
        : generated.map(trackFromSong).toList();
  }

  Future<List<Track>> artistStationTracks(ArtistRef seed) async {
    if (seed.id <= 0) return const <Track>[];
    final similar = await gateway.similarArtists(seed.id);
    final artistIds = <int>[
      seed.id,
      ...similar.take(4).map((artist) => artist.id),
    ];
    final groups = await Future.wait<List<GatewaySong>>(
      artistIds.map(
        (id) =>
            gateway.artistTopSongs(id).catchError((_) => const <GatewaySong>[]),
      ),
    );
    final List<Track> station = <Track>[];
    final Set<int> seen = <int>{};
    for (var row = 0; row < 8; row++) {
      for (final songs in groups) {
        if (row >= songs.length) continue;
        final song = songs[row];
        if (seen.add(song.id)) station.add(trackFromSong(song));
      }
    }
    return station;
  }

  Future<MusicChart> matchChart(MusicChart chart) => _cached(
    'chart-match-v2:${chart.id}',
    const Duration(hours: 6),
    MusicChart.fromJson,
    (value) => value.toJson(),
    () async {
      final List<ChartEntry> entries = <ChartEntry>[];
      final int matchCount = math.min(20, chart.entries.length);
      for (var start = 0; start < matchCount; start += 4) {
        final int end = math.min(start + 4, matchCount);
        entries.addAll(
          await Future.wait(
            chart.entries.sublist(start, end).map(_matchChartEntry),
          ),
        );
      }
      entries.addAll(chart.entries.skip(matchCount));
      return MusicChart(
        id: chart.id,
        title: chart.title,
        source: chart.source,
        issueLabel: chart.issueLabel,
        entries: entries,
        accent: chart.accent,
        providerKey: chart.providerKey,
        logoUrl: chart.logoUrl,
        issues: chart.issues,
        selectedIssueId: chart.selectedIssueId,
      );
    },
  );

  Future<ChartEntry> _matchChartEntry(ChartEntry entry) async {
    Track? match;
    try {
      final String sourceArtist = _normaliseMusicText(entry.artist);
      final String sourceTitle = _normaliseMusicText(entry.title);
      final String query = <String>[
        entry.title,
        entry.artist,
      ].where((part) => part.trim().isNotEmpty).join(' ');
      final candidates = await gateway
          .search(query, limit: 8, useCloudSearch: true)
          .timeout(const Duration(seconds: 5));
      double bestScore = 0;
      for (final candidate in candidates) {
        final double score = _chartMatchScore(entry, candidate);
        if (score > bestScore) {
          bestScore = score;
          match = trackFromSong(candidate);
        }
      }
      // Some trusted chart archives only retain the canonical song title.
      // In that case an exact title match is still useful and is the only
      // route to a playable result; partial-title matches remain rejected.
      final requiredScore = sourceArtist.isEmpty ? .65 : .78;
      if (bestScore < requiredScore ||
          (sourceArtist.isEmpty && sourceTitle.runes.length < 4)) {
        match = null;
      }
    } catch (_) {
      match = null;
    }
    return entry.copyWith(track: match);
  }

  static double _chartMatchScore(ChartEntry entry, GatewaySong song) {
    final String title = _normaliseMusicText(entry.title);
    final String translated = _normaliseMusicText(entry.translatedTitle ?? '');
    final String candidateTitle = _normaliseMusicText(song.title);
    double score = 0;
    if (title.isNotEmpty && candidateTitle == title) {
      score += .65;
    } else if (translated.isNotEmpty && candidateTitle == translated) {
      score += .6;
    } else if (title.length >= 3 &&
        (candidateTitle.contains(title) || title.contains(candidateTitle))) {
      score += .45;
    }
    final String sourceArtist = _normaliseMusicText(entry.artist);
    final String candidateArtist = _normaliseMusicText(song.artistLine);
    if (sourceArtist.isNotEmpty && candidateArtist.isNotEmpty) {
      if (sourceArtist == candidateArtist) {
        score += .35;
      } else {
        final sourceParts = sourceArtist.split(' ').where((p) => p.length > 1);
        if (sourceParts.any(candidateArtist.contains)) score += .22;
      }
    }
    return score;
  }

  static String _normaliseMusicText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\b(feat|ft|with)\.?\b.*$'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u3040-\u30ff\u3400-\u9fff]+'), ' ')
      .trim();

  /// Reuses recent snapshots; expired snapshots remain available offline.
  Future<List<Track>> playlistTracks(String playlistId) => _cached(
    'playlist-v2:$_scope:$playlistId',
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
      final List<GatewaySong> ordered = <GatewaySong>[];
      if (playlist.trackIds.isNotEmpty) {
        for (int offset = 0; offset < playlist.trackIds.length; offset += 500) {
          final int end = math.min(offset + 500, playlist.trackIds.length);
          ordered.addAll(
            await gateway.songDetails(playlist.trackIds.sublist(offset, end)),
          );
        }
      }
      if (playlist.trackIds.isEmpty ||
          ordered.any((song) => song.title.isEmpty || song.artists.isEmpty)) {
        // Some editorial/recommendation playlists omit trackIds from detail.
        // The dedicated paged route also repairs incomplete song/detail rows.
        final int expected = math.max(
          1,
          math.max(playlist.trackCount, playlist.trackIds.length),
        );
        final List<GatewaySong> complete = <GatewaySong>[];
        for (int offset = 0; offset < expected; offset += 500) {
          final page = await gateway.playlistTracks(
            id,
            limit: 500,
            offset: offset,
          );
          final rawSongs = page['songs'];
          final songs = rawSongs is List
              ? rawSongs
                    .whereType<Map<String, dynamic>>()
                    .map((item) {
                      final nested = item['song'] ?? item['data'];
                      return GatewaySong.fromJson(
                        nested is Map<String, dynamic> ? nested : item,
                      );
                    })
                    .where((song) => song.id > 0)
                    .toList()
              : const <GatewaySong>[];
          complete.addAll(songs);
          if (songs.length < 500) break;
        }
        if (complete.isNotEmpty) {
          ordered
            ..clear()
            ..addAll(complete);
        }
      }
      _online = true;
      return ordered.map(trackFromSong).toList();
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

  static List<Track> _decodeTracks(dynamic raw) => (raw as List? ?? const [])
      .map((item) => Track.fromJson(item as Map<String, dynamic>))
      .toList();
  static List<Playlist> _decodePlaylists(dynamic raw) =>
      (raw as List? ?? const [])
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
    albums: (json['albums'] as List? ?? const [])
        .map((a) => Album.fromJson(a as Map<String, dynamic>))
        .toList(),
    editorialPlaylists: _decodePlaylists(json['editorialPlaylists']),
  );
  static Map<String, dynamic> _encodeHome(HomeFeed value) => {
    'featured': value.featured?.toJson(),
    'recommended': value.recommended.map((p) => p.toJson()).toList(),
    'featuredTracks': value.featuredTracks.map((t) => t.toJson()).toList(),
    'quick': value.quick.map((t) => t.toJson()).toList(),
    'playlists': value.playlists.map((p) => p.toJson()).toList(),
    'albums': value.albums.map((a) => a.toJson()).toList(),
    'editorialPlaylists': value.editorialPlaylists
        .map((p) => p.toJson())
        .toList(),
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
