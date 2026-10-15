import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewayPlaylist>> personalizedPlaylists({int limit = 12}) async =>
      const [];
  final List<List<int>> detailPages = <List<int>>[];
  bool failSearch = false;

  @override
  Future<List<GatewayPlaylist>> topPlaylists({
    String category = '全部',
    int limit = 12,
    int offset = 0,
  }) async => <GatewayPlaylist>[
    const GatewayPlaylist(id: 12, name: '真实歌单', trackCount: 501),
  ];

  @override
  Future<Map<String, dynamic>> playlistDetail(
    int id, {
    int subscriberLimit = 8,
  }) async => <String, dynamic>{
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

void main() {
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
