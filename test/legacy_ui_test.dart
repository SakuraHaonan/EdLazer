import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/interface_settings.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  translatedTitle: '测试译名',
);

const Playlist _playlist = Playlist(
  id: '12',
  name: '测试歌单',
  trackIds: <String>[],
  coverSeed: 1,
  trackCount: 3,
  description: '来自你的听歌偏好',
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[_playlist],
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[_playlist],
    albums: <Album>[],
  );
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]第一句');
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
  @override
  Future<SearchResults> search(String query) async => const SearchResults(
    tracks: <Track>[_track],
    playlists: <Playlist>[_playlist],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the legacy theme keeps the Lazer palette and type ramp', () {
    final ThemeData dark = buildLegacyTheme(brightness: Brightness.dark);
    expect(dark.colorScheme.primary, LegacyTokens.nightBlue);
    expect(dark.colorScheme.surface, LegacyTokens.nightRaised);
    expect(dark.textTheme.displaySmall?.fontSize, 34);
    expect(dark.textTheme.headlineMedium?.fontSize, 25);
    expect(dark.textTheme.bodyMedium?.fontSize, 14);

    final ThemeData light = buildLegacyTheme();
    expect(light.colorScheme.primary, LegacyTokens.lakeBlue);
    expect(light.colorScheme.surface, LegacyTokens.paperRaised);
  });

  test('the UI style defaults to Nextgen and persists the choice', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.uiStyle, AppUiStyle.nextgen);
    await state.setUiStyle(AppUiStyle.legacy);
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_ui_style'),
      'legacy',
    );

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.uiStyle, AppUiStyle.legacy);
    expect(AppUiStyleLabels.parse('nope'), AppUiStyle.nextgen);
    expect(AppUiStyleLabels.parse(null), AppUiStyle.nextgen);
  });

  testWidgets('the legacy shell draws rail, discovery page and transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) => MaterialApp(
          theme: buildLegacyTheme(brightness: Brightness.dark),
          home: LegacyShell(state: state),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Rail chrome and the discovery page. 'Lazer' is both the rail wordmark
    // and the empty transport's artist line.
    expect(find.text('Lazer'), findsWidgets);
    expect(find.text('主页'), findsOneWidget);
    expect(find.text('音乐库'), findsOneWidget);
    expect(find.text('我喜欢'), findsOneWidget);
    expect(find.text('今天为你整理'), findsOneWidget);
    expect(find.text('测试歌单'), findsWidgets);
    expect(find.text('未选择曲目'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 音乐库 shows the recommended playlists for a guest.
    await tester.tap(find.text('音乐库').first);
    await tester.pumpAndSettle();
    expect(find.text('推荐歌单'), findsOneWidget);

    // 设置 carries the interface switch back to Nextgen UI.
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget);
    expect(find.byType(SegmentedButton<AppUiStyle>), findsOneWidget);
    await tester.tap(find.text('Nextgen UI'));
    await tester.pumpAndSettle();
    expect(state.uiStyle, AppUiStyle.nextgen);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy shell folds into bottom tabs on a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('音乐库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Nextgen settings expose the interface style switch', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) => MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: InterfaceSettings(state: state)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('界面风格'), findsOneWidget);
    expect(find.text('Nextgen UI'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<AppUiStyle>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Legacy UI').last);
    await tester.pumpAndSettle();
    expect(state.uiStyle, AppUiStyle.legacy);
    expect(
      (await SharedPreferences.getInstance()).getString('lazer_ui_style'),
      'legacy',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy shell lays out at every window size', (tester) async {
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    for (final Size size in <Size>[
      const Size(520, 900),
      const Size(800, 700),
      const Size(1024, 768),
      const Size(1600, 1000),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(brightness: Brightness.dark),
          home: LegacyShell(key: ValueKey<String>('$size'), state: state),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'legacy shell overflowed at $size',
      );
    }
  });

  testWidgets('the legacy top bar searches and lists the results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'まにまに');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('まにまに'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
