import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/cache/disk_cache.dart';
import 'package:lazer_nextgen/data/biliboard.dart';
import 'package:lazer_nextgen/data/billboard.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewayPlaylist>> personalizedPlaylists({int limit = 12}) async =>
      const [];
  final List<List<int>> detailPages = <List<int>>[];
  bool failSearch = false;
  bool failPlaylist = false;
  bool failAll = false;
  int playlistCalls = 0;
  int collectionCalls = 0;
  int audioCalls = 0;
  int lyricCalls = 0;

  @override
  Future<GatewayLyrics> preferredLyrics(int id) async {
    lyricCalls++;
    if (failAll) throw const SocketException('offline');
    return GatewayLyrics(lrc: '[00:00]Line $lyricCalls', tlyric: '[00:00]翻译');
  }

  @override
  Future<List<GatewayPlaylist>> topPlaylists({
    String category = '全部',
    int limit = 12,
    int offset = 0,
  }) async {
    if (failAll) throw const SocketException('offline');
    return const [GatewayPlaylist(id: 12, name: '真实歌单', trackCount: 501)];
  }

  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async {
    playlistCalls++;
    if (failPlaylist || failAll) throw const SocketException('offline');
    return <String, dynamic>{
      'code': 200,
      'playlist': <String, dynamic>{
        'id': id,
        'name': '真实歌单',
        'trackCount': 501,
        'trackIds': <Map<String, int>>[
          for (int songId = 1; songId <= 501; songId++)
            <String, int>{'id': songId},
        ],
      },
    };
  }

  @override
  Future<List<GatewayPlaylist>> userPlaylists(
    int uid, {
    int limit = 30,
    int offset = 0,
  }) async {
    collectionCalls++;
    if (failAll) throw const SocketException('offline');
    return [
      GatewayPlaylist(
        id: uid * 10,
        name: '喜欢的音乐',
        specialType: 5,
        trackCount: 501,
      ),
    ];
  }

  @override
  Future<GatewaySongUrl?> songUrl(int id, {String level = 'exhigh'}) async {
    audioCalls++;
    throw const SocketException('offline');
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async {
    detailPages.add(ids);
    return ids
        .map(
          (id) => GatewaySong(
            id: id,
            title: '曲目 $id',
            artists: const <String>['音乐人'],
            albumName: '专辑',
            albumId: 9,
            duration: const Duration(minutes: 3),
            coverUrl: 'https://example.com/$id.jpg',
          ),
        )
        .toList();
  }

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    if (failSearch) throw StateError('network unavailable');
    return songDetails(<int>[42]);
  }

  @override
  Future<List<GatewayAlbum>> searchAlbums(
    String keywords, {
    int limit = 10,
  }) async => const <GatewayAlbum>[];

  @override
  Future<List<GatewayPlaylist>> searchPlaylists(
    String keywords, {
    int limit = 20,
  }) async => const <GatewayPlaylist>[];
}

class _ChartGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    final match = RegExp(r'^Song (\d+)').firstMatch(keywords);
    if (match == null) return const <GatewaySong>[];
    final id = int.parse(match.group(1)!);
    return <GatewaySong>[
      GatewaySong(
        id: id,
        title: 'Song $id',
        artists: <String>['Artist $id'],
        albumName: 'Album $id',
        duration: const Duration(minutes: 3),
      ),
    ];
  }
}

class _StaticBillboard extends BillboardClient {
  @override
  Future<MusicChart?> latestChart() async => const MusicChart(
    id: 'billboard:test',
    title: 'Billboard Hot 100',
    source: 'Billboard',
    issueLabel: 'Current',
    entries: <ChartEntry>[],
    providerKey: 'billboard:hot-100',
  );
}

class _RecoveringBiliboard extends BiliboardClient {
  int calls = 0;

  @override
  Future<List<MusicChart>> latestCharts() async {
    calls++;
    if (calls == 1) throw const SocketException('temporary outage');
    return const <MusicChart>[
      MusicChart(
        id: 'biliboard:1:124',
        title: '周榜',
        source: 'Biliboard',
        issueLabel: '2026 · 第 43 周',
        entries: <ChartEntry>[],
        providerKey: 'biliboard:1',
      ),
    ];
  }
}

class _FallbackChartGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    if (keywords != 'Nicole Kidman') return const <GatewaySong>[];
    return const <GatewaySong>[
      GatewaySong(
        id: 6,
        title: 'Nicole Kidman',
        artists: <String>['ADÉLA'],
        albumName: 'The Provocateur',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

class _SharedSongGateway extends NeteaseGateway {
  int searchCalls = 0;

  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async {
    searchCalls++;
    if (searchCalls > 1) throw const SocketException('rate limited');
    return const <GatewaySong>[
      GatewaySong(
        id: 7,
        title: 'Shared Song',
        artists: <String>['Producer'],
        albumName: 'Shared Album',
        duration: Duration(minutes: 3),
      ),
    ];
  }
}

class _BiliboardAliasGateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> search(
    String keywords, {
    GatewaySearchType type = GatewaySearchType.song,
    int limit = 30,
    int offset = 0,
    bool useCloudSearch = false,
  }) async => const <GatewaySong>[
    GatewaySong(
      id: 8,
      title: 'シャルル',
      artists: <String>['須田景凪'],
      albumName: 'Corridor',
      duration: Duration(minutes: 4),
    ),
  ];
}

void main() {
  group('persistent catalogue cache', () {
    late Directory directory;
    late DiskCache disk;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('lazer-catalog-test-');
      disk = DiskCache(directory: () async => directory);
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
      'lyrics refresh bypasses cached data and retains translations offline',
      () async {
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        const track = Track(
          id: '42',
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          coverSeed: 0,
        );
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 1');
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 1');
        expect(gateway.lyricCalls, 1);
        await catalog.invalidateLyrics(track.id);
        expect((await catalog.lyricsFor(track))?.lrc, '[00:00]Line 2');
        gateway.failAll = true;
        await catalog.invalidateLyrics(track.id);
        final offline = await catalog.lyricsFor(track);
        expect(offline?.lrc, '[00:00]Line 2');
        expect(offline?.tlyric, '[00:00]翻译');
      },
    );

    test(
      'complete playlist is reused after restart, refreshed and available stale offline',
      () async {
        final firstGateway = _Gateway();
        final first = Catalog(gateway: firstGateway, cache: disk);
        final loaded = await Future.wait([
          first.playlistTracks('12'),
          first.playlistTracks('12'),
        ]);
        expect(loaded.first.length, 501);
        expect(firstGateway.playlistCalls, 1);
        expect(firstGateway.detailPages.map((page) => page.length), [500, 1]);
        final gateway = _Gateway()..failPlaylist = true;
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        final cached = await restarted.playlistTracks('12');
        expect(gateway.playlistCalls, 0);
        expect(
          cached.map((track) => track.id),
          loaded.first.map((track) => track.id),
        );
        expect(cached.first.coverUrl, loaded.first.first.coverUrl);
        final stale = await restarted.refreshPlaylist('12');
        expect(gateway.playlistCalls, 1);
        expect(stale.length, 501);
        gateway.failPlaylist = false;
        expect((await restarted.playlistTracks('12')).length, 501);
        expect(gateway.playlistCalls, 2);
      },
    );

    test(
      'personal collections and private playlists are separated by session',
      () async {
        final gateway = _Gateway()..sessionCookie = 'MUSIC_U=account-a';
        final catalog = Catalog(gateway: gateway, cache: disk);
        expect((await catalog.userCollections(7)).liked?.id, '70');
        await catalog.playlistTracks('12');
        gateway.failAll = true;
        expect((await catalog.userCollections(7)).liked?.trackCount, 501);
        await catalog.invalidateCollections(7);
        expect((await catalog.userCollections(7)).liked?.id, '70');
        gateway.sessionCookie = 'MUSIC_U=account-b';
        await expectLater(
          catalog.userCollections(8),
          throwsA(isA<SocketException>()),
        );
        await expectLater(
          catalog.playlistTracks('12'),
          throwsA(isA<SocketException>()),
        );
        gateway.clearSession();
        await expectLater(
          catalog.playlistTracks('12'),
          throwsA(isA<SocketException>()),
        );
      },
    );

    test(
      'home feed survives restart with real recommendations and metadata',
      () async {
        final catalog = Catalog(gateway: _Gateway(), cache: disk);
        final feed = (await catalog.loadHome())!;
        await disk.expireJson('home:guest:0');
        final gateway = _Gateway()..failAll = true;
        final restarted = Catalog(
          gateway: gateway,
          cache: DiskCache(directory: () async => directory),
        );
        final offline = (await restarted.loadHome())!;
        expect(offline.recommended.single.id, feed.recommended.single.id);
        expect(offline.quick.length, feed.quick.length);
        expect(offline.featured?.title, feed.featured?.title);
        expect(restarted.online, isFalse);
      },
    );

    test(
      'audio playback resolves a cached file before contacting the service',
      () async {
        final file = await disk.put(
          CacheBucket.audio,
          '42',
          () => Stream.value([1, 2, 3]),
          extension: 'mp3',
        );
        final gateway = _Gateway();
        final catalog = Catalog(gateway: gateway, cache: disk);
        const track = Track(
          id: '42',
          title: '',
          artist: '',
          album: '',
          duration: Duration.zero,
          coverSeed: 0,
        );
        expect(await catalog.audioUrlFor(track), file!.uri.toString());
        expect(gateway.audioCalls, 0);
      },
    );
  });

  test('song translations survive gateway parsing and catalogue mapping', () {
    final song = GatewaySong.fromJson(<String, dynamic>{
      'id': 42,
      'name': 'Original title',
      'tns': ['中文译名', 'Original title', '中文译名'],
    });
    expect(Catalog.trackFromSong(song).translatedTitle, '中文译名');
    final alternate = GatewaySong.fromJson(<String, dynamic>{
      'id': 43,
      'name': 'Another title',
      'transNames': ['另一首的译名'],
    });
    expect(alternate.translatedTitle, '另一首的译名');
  });

  test(
    'chart matching resolves every entry instead of only the first page',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _ChartGateway();
      final catalog = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      final chart = MusicChart(
        id: 'billboard:test-100',
        title: 'Billboard Hot 100',
        source: 'Billboard',
        issueLabel: 'Test issue',
        entries: <ChartEntry>[
          for (var rank = 1; rank <= 100; rank++)
            ChartEntry(rank: rank, title: 'Song $rank', artist: 'Artist $rank'),
        ],
      );

      final matched = await catalog.matchChart(chart);

      expect(
        matched.entries.where((entry) => entry.track != null),
        hasLength(100),
      );
      expect(gateway.searchCalls, 100);
    },
  );

  test('a temporary Biliboard failure is retried instead of cached', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-source-cache-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final biliboard = _RecoveringBiliboard();
    final catalog = Catalog(
      gateway: _Gateway(),
      cache: DiskCache(directory: () async => directory),
      billboard: _StaticBillboard(),
      charts: biliboard,
    );

    final first = await catalog.discoveryCharts();
    final recovered = await catalog.discoveryCharts();

    expect(first.map((chart) => chart.providerKey), <String?>[
      'billboard:hot-100',
    ]);
    expect(
      recovered.map((chart) => chart.providerKey),
      contains('biliboard:1'),
    );
    expect(biliboard.calls, 2);
  });

  test('chart matching retries by title and folds artist diacritics', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lazer-chart-fallback-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final gateway = _FallbackChartGateway();
    final catalog = Catalog(
      gateway: gateway,
      cache: DiskCache(directory: () async => directory),
    );
    const chart = MusicChart(
      id: 'billboard:fallback',
      title: 'Billboard Hot 100',
      source: 'Billboard',
      issueLabel: 'Test issue',
      entries: <ChartEntry>[
        ChartEntry(rank: 1, title: 'Nicole Kidman', artist: 'ADELA'),
      ],
    );

    final matched = await catalog.matchChart(chart);

    expect(matched.entries.single.track?.id, '6');
    expect(gateway.searchCalls, 2);
  });

  test(
    'the same song reuses a positive match across Biliboard boards',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-shared-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final gateway = _SharedSongGateway();
      final catalog = Catalog(
        gateway: gateway,
        cache: DiskCache(directory: () async => directory),
      );
      MusicChart board(int id) => MusicChart(
        id: 'biliboard:$id:1',
        title: 'Board $id',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:$id',
        entries: const <ChartEntry>[
          ChartEntry(rank: 1, title: 'Shared Song', artist: 'Producer'),
        ],
      );

      final weekly = await catalog.matchChart(board(1));
      final legends = await catalog.matchChart(board(2));

      expect(weekly.entries.single.track?.id, '7');
      expect(legends.entries.single.track?.id, '7');
      expect(gateway.searchCalls, 1);
    },
  );

  test(
    'Biliboard accepts an exact title when producer aliases differ',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer-chart-alias-match-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final catalog = Catalog(
        gateway: _BiliboardAliasGateway(),
        cache: DiskCache(directory: () async => directory),
      );
      const chart = MusicChart(
        id: 'biliboard:2:84',
        title: '传说曲周榜',
        source: 'Biliboard',
        issueLabel: 'Current',
        providerKey: 'biliboard:2',
        entries: <ChartEntry>[
          ChartEntry(rank: 1, title: 'シャルル', artist: 'バルーン'),
        ],
      );

      final matched = await catalog.matchChart(chart);

      expect(matched.entries.single.track?.id, '8');
    },
  );

  test('home and search contain only gateway music', () async {
    final gateway = _Gateway();
    final catalog = Catalog(gateway: gateway);
    final feed = await catalog.loadHome();
    expect(feed?.playlists.single.name, '真实歌单');
    expect(feed?.quick.length, 8);
    expect(feed?.recommended.single.id, '12');
    final results = await catalog.search('曲目');
    expect(results.tracks.single.id, '42');
    expect(results.tracks.single.coverUrl, 'https://example.com/42.jpg');
  });

  test('playlist loads every page and preserves service order', () async {
    final gateway = _Gateway();
    final tracks = await Catalog(gateway: gateway).playlistTracks('12');
    expect(gateway.detailPages.map((page) => page.length), <int>[500, 1]);
    expect(tracks.length, 501);
    expect(tracks.first.id, '1');
    expect(tracks.last.id, '501');
  });

  test(
    'search failure propagates instead of returning sample content',
    () async {
      final gateway = _Gateway()..failSearch = true;
      await expectLater(
        Catalog(gateway: gateway).search('曲目'),
        throwsStateError,
      );
    },
  );
}
