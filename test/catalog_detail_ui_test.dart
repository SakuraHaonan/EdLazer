import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/catalog_details.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/screens/catalog_detail_page.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/catalog_links.dart';

const _artists = [
  ArtistRef(id: 11, name: '音乐人甲'),
  ArtistRef(id: 22, name: '音乐人乙'),
];
Album _album(int id) => Album(
  id: '$id',
  title: '沿途的风 $id',
  artist: '音乐人甲 / 音乐人乙',
  artists: _artists,
  year: '2026',
  coverSeed: id,
  note: '',
  trackCount: 3,
);
Track _track(int id) => Track(
  id: '$id',
  title: '歌曲 $id',
  artist: '音乐人甲 / 音乐人乙',
  artists: _artists,
  album: '沿途的风 77',
  albumId: 77,
  duration: const Duration(minutes: 3),
  coverSeed: id,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  final artistRequests = <int>[];
  final offsets = <int>[];
  bool fail = false;
  @override
  Future<ArtistDetails> artistDetails(
    ArtistRef seed, {
    bool force = false,
  }) async {
    artistRequests.add(seed.id);
    if (fail) throw const SocketException('offline');
    return ArtistDetails(
      artist: seed,
      tracks: [for (var i = 1; i <= 3; i++) _track(i)],
      description: '用音乐记录生活，也记录每一次出发。' * 16,
      musicCount: 50,
      albumCount: 32,
    );
  }

  @override
  Future<AlbumDetails> albumDetails(int id, {bool force = false}) async {
    if (fail) throw const SocketException('offline');
    return AlbumDetails(
      album: _album(id),
      tracks: [for (var i = 1; i <= 3; i++) _track(i)],
      description: '这是一张关于旅程和回忆的专辑。' * 16,
      company: '音乐工作室',
      publishTime: 1704067200000,
    );
  }

  @override
  Future<ArtistAlbumPage> artistAlbumPage(
    int id, {
    int offset = 0,
    bool force = false,
  }) async {
    offsets.add(offset);
    return ArtistAlbumPage(
      albums: offset == 0 ? [_album(77), _album(78)] : [_album(78), _album(79)],
      more: offset == 0,
      receivedCount: 2,
    );
  }

  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('diag/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
        .load();
  });
  testWidgets(
    'artist entry deduplicates choices, loads the selected profile, pages albums and returns',
    (tester) async {
      final catalog = _Catalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Center(
              child: ArtistNameLink(
                state: state,
                artists: [
                  ..._artists,
                  _artists.first,
                  const ArtistRef(id: 0, name: '无效'),
                ],
                fallback: '歌手入口',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('歌手入口'));
      await tester.pumpAndSettle();
      expect(find.text('音乐人甲'), findsOneWidget);
      expect(find.text('无效'), findsNothing);
      await tester.tap(find.text('音乐人乙'));
      await tester.pumpAndSettle();
      expect(catalog.artistRequests, [22]);
      expect(
        state.current,
        isNull,
        reason: 'opening a profile must preserve playback',
      );
      expect(find.text('歌手详情'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('专辑'), 200);
      await tester.tap(find.text('专辑'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('加载更多专辑'), 200);
      await tester.tap(find.text('加载更多专辑'));
      await tester.pumpAndSettle();
      expect(catalog.offsets, [0, 2]);
      expect(find.text('沿途的风 78'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('沿途的风 79'), 200);
      await tester.tap(find.text('沿途的风 79'));
      await tester.pumpAndSettle();
      expect(find.text('专辑详情'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('歌手详情'), findsOneWidget);
      expect(catalog.artistRequests, [22]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'song metadata opens album details without playing and play-all uses the full track list',
    (tester) async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      var rowPlays = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: TrackRow(
              state: state,
              track: _track(1),
              index: 1,
              isCurrent: false,
              onPlay: () => rowPlays++,
            ),
          ),
        ),
      );
      await tester.tap(find.text('沿途的风 77'));
      await tester.pumpAndSettle();
      expect(find.text('专辑详情'), findsOneWidget);
      expect(rowPlays, 0);
      expect(state.current, isNull);
      await tester.tap(find.text('播放全部'));
      await tester.pumpAndSettle();
      expect(state.queue.map((track) => track.id), ['1', '2', '3']);
      expect(state.current!.artists.map((artist) => artist.id), [11, 22]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed details can retry and a direct single-artist entry skips the chooser',
    (tester) async {
      final catalog = _Catalog()..fail = true;
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: Center(
              child: ArtistNameLink(
                state: state,
                artists: [_artists.first],
                fallback: '单歌手',
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('单歌手'));
      await tester.pumpAndSettle();
      expect(find.text('选择歌手'), findsNothing);
      await tester.ensureVisible(find.text('重试'));
      await tester.pumpAndSettle();
      catalog.fail = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('歌手资料加载失败，请重试。'), findsNothing);
      expect(find.text('播放热门歌曲'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'details fit mobile and desktop in both themes and support enlarged text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      for (final width in [320.0, 1100.0]) {
        tester.view.physicalSize = Size(width, width == 320 ? 700 : 850);
        for (final dark in [false, true]) {
          final key = GlobalKey();
          await tester.pumpWidget(
            MaterialApp(
              theme: buildAppTheme(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(width == 320 ? 1.4 : 1),
                ),
                child: child!,
              ),
              home: RepaintBoundary(
                key: key,
                child: CatalogDetailPage.album(state: state, album: _album(77)),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await _capture(
            tester,
            key,
            'album_detail_${width.round()}_${dark ? 'dark' : 'light'}',
          );
          expect(tester.takeException(), isNull);
        }
      }
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: RepaintBoundary(
            key: key,
            child: CatalogDetailPage.artist(
              state: state,
              artist: _artists.first,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, key, 'artist_detail_1100');
      await tester.tap(find.text('专辑').last);
      await tester.pumpAndSettle();
      await _capture(tester, key, 'artist_albums_1100');
      expect(tester.takeException(), isNull);
    },
  );
}
