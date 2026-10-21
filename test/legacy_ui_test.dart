import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/apple_ui.dart';

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

class _SignedInState extends AppState {
  _SignedInState() : super(catalog: _Catalog());

  @override
  SessionUser get user => const SessionUser(
    name: 'CYP2D6_Official',
    handle: '@23',
    method: AuthMethod.cookie,
    detail: '3 个字段',
    userId: 23,
    avatarUrl: 'https://example.com/avatar.jpg',
    vipType: 11,
  );

  @override
  bool get isGuest => false;
}

/// The legacy shell under a theme whose backdrop animation is disabled, so
/// `pumpAndSettle` can settle: the flowing canvas keeps a ticker running, and
/// reduced-motion is exactly how the shell handles that for tests and users.
Widget _legacyApp(AppState state) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: LegacyShell(state: state),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the legacy theme keeps the Lazer palette and type ramp', () {
    final ThemeData dark = buildLegacyTheme(brightness: Brightness.dark);
    expect(dark.colorScheme.primary, LegacyTokens.nightBlue);
    expect(dark.colorScheme.surface, LegacyTokens.nightPaper);
    expect(dark.textTheme.displaySmall?.fontSize, 36);
    expect(dark.textTheme.headlineMedium?.fontSize, 28);
    expect(dark.textTheme.bodyMedium?.fontSize, 14);

    final ThemeData light = buildLegacyTheme();
    expect(light.colorScheme.primary, const Color(0xFF35657D));
    expect(light.colorScheme.surface, LegacyTokens.paperRaised);
    // Every Material 3 surface role is explicit; none of them may fall back
    // to Flutter's purple baseline scheme.
    expect(light.colorScheme.surfaceContainerLowest, const Color(0xFFFFFFFF));
    expect(light.colorScheme.surfaceContainerHighest, const Color(0xFFE3DED4));
    expect(dark.colorScheme.surfaceDim, const Color(0xFF0F1619));
    expect(dark.colorScheme.surfaceBright, const Color(0xFF394448));
    expect(dark.colorScheme.inversePrimary, const Color(0xFF35657D));
    expect(light.useMaterial3, isTrue);
    expect(dark.textTheme.labelSmall?.fontSize, 11);
    expect(
      dark.cardTheme.shape,
      const RoundedRectangleBorder(borderRadius: AppShape.lgRadius),
    );
  });

  testWidgets('the legacy shell draws rail, discovery page and transport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
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

    // 设置 opens the preferences page.
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    expect(find.text('配色'), findsOneWidget);
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
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('音乐库'), findsOneWidget);
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
      await tester.pumpWidget(_legacyApp(state));
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'legacy shell overflowed at $size',
      );
    }
  });

  testWidgets('the legacy settings expose every preference', (tester) async {
    tester.view.physicalSize = const Size(1280, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();

    for (final String label in <String>[
      '配色',
      '设备形态',
      '界面布局',
      'DPI 缩放',
      '自动调节 DPI 缩放',
      '背景',
      '内容不透明度',
      '主题',
      '语言',
      '震动反馈',
      '歌词控件自动隐藏',
      '歌词字号',
      '歌词粗细',
      '歌词模糊',
      '手动浏览后恢复跟随',
      '滚动惯性',
      '滚动加速度',
      '刷新曲库',
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing $label');
    }
    expect(find.text('70%'), findsOneWidget);
    // DPI 100% and the default scroll acceleration both read 100%.
    expect(find.text('100%'), findsWidgets);

    Finder controlFor<T extends Widget>(String label) => find.descendant(
      of: find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first,
      matching: find.byType(T),
    );

    // The automatic scale switch is on out of the box, and turning it off
    // leaves the manual scale in place.
    await tester.tap(controlFor<Switch>('自动调节 DPI 缩放'));
    await tester.pumpAndSettle();
    expect(state.autoDpiScale, isFalse);

    // The DPI slider writes a manual scale.
    final Finder dpi = controlFor<Slider>('DPI 缩放');
    await tester.ensureVisible(dpi);
    await tester.drag(dpi, const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(state.dpiScale, greaterThan(1.0));

    // Lyrics: size slider, weight chips and the blur switch.
    final Finder lyricSize = controlFor<Slider>('歌词字号');
    await tester.ensureVisible(lyricSize);
    await tester.drag(lyricSize, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(state.lyricFontSize, greaterThan(22));
    await tester.ensureVisible(find.text('粗体'));
    await tester.tap(find.text('粗体'));
    await tester.pumpAndSettle();
    expect(state.lyricFontWeight, 700);
    await tester.ensureVisible(find.text('歌词模糊'));
    await tester.tap(controlFor<Switch>('歌词模糊'));
    await tester.pumpAndSettle();
    expect(state.lyricBlurEnabled, isFalse);

    // Haptics and the scroll sliders.
    await tester.ensureVisible(find.text('震动反馈'));
    await tester.tap(controlFor<Switch>('震动反馈'));
    await tester.pumpAndSettle();
    expect(state.hapticsEnabled, isFalse);
    final Finder inertia = controlFor<Slider>('滚动惯性');
    await tester.ensureVisible(inertia);
    await tester.drag(inertia, const Offset(-800, 0));
    await tester.pumpAndSettle();
    expect(state.scrollRetention, lessThan(0.90));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy top bar searches and lists the results', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'まにまに');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('まにまに'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
  testWidgets('signed-in rail shows the artwork avatar and VIP status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = _SignedInState();
    addTearDown(state.dispose);
    await tester.pumpWidget(_legacyApp(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('CYP2D6_Official'), findsOneWidget);
    expect(find.text('黑胶会员'), findsOneWidget);
    expect(find.text('3 个字段'), findsNothing);
    final tile = find.ancestor(
      of: find.text('CYP2D6_Official'),
      matching: find.byType(AppleListTile),
    );
    expect(tile, findsOneWidget);
    expect(
      find.descendant(of: tile, matching: find.byType(Image)),
      findsOneWidget,
      reason: 'the signed-in account must use its avatar, not an initial',
    );
    expect(
      find.descendant(of: tile, matching: find.text('C')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

}
