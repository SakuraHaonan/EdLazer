import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/widgets/liquid_glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Track _first = Track(
  id: '1',
  title: 'パベル',
  artist: 'いよわ',
  album: 'パベル',
  duration: Duration(minutes: 2, seconds: 26),
  coverSeed: 3,
);

const Track _second = Track(
  id: '2',
  title: '秒針を噛む',
  artist: 'ずっと真夜中でいいのに。',
  album: '秒針を噛む',
  duration: Duration(minutes: 3, seconds: 40),
  coverSeed: 8,
);

class _Engine implements AudioEngine {
  final StreamController<void> _completed = StreamController<void>.broadcast();

  @override
  bool active = false;

  @override
  Duration position = Duration.zero;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  Future<void> setUrl(String url) async {
    active = true;
  }

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {
    this.position = position;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  Stream<void> get completed => _completed.stream;

  @override
  void dispose() {
    unawaited(_completed.close());
  }
}

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
    recommended: <Playlist>[],
    featuredTracks: <Track>[_first, _second],
    quick: <Track>[_first],
    playlists: <Playlist>[],
    albums: <Album>[],
  );

  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'https://example.invalid/${track.id}.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Widget _app(AppState state, {required Brightness brightness}) {
  final ThemeData theme = buildLegacyTheme(brightness: brightness);
  return MaterialApp(
    theme: theme,
    darkTheme: theme,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: RepaintBoundary(
        key: const ValueKey<String>('chrome-shot'),
        child: child!,
      ),
    ),
    home: LegacyShell(state: state),
  );
}

Future<void> _capture(WidgetTester tester, String name) async {
  await tester.pump();
  final RenderRepaintBoundary boundary = tester
      .renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey<String>('chrome-shot')),
      );
  final ui.Image image = (await tester.runAsync<ui.Image>(
    () => boundary.toImage(pixelRatio: 2),
  ))!;
  final ByteData? data = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.png),
  );
  image.dispose();
  final File file = File('build/chrome-shots/$name.png');
  await tester.runAsync(() async {
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
  });
}

Future<void> _loadScreenshotFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final FontLoader miSans = FontLoader('MiSans');
  for (final String name in <String>[
    'MiSans-Light.ttf',
    'MiSans-Normal.ttf',
    'MiSans-Regular.ttf',
    'MiSans-Medium.ttf',
    'MiSans-Semibold.ttf',
    'MiSans-Bold.ttf',
  ]) {
    miSans.addFont(rootBundle.load('assets/fonts/$name'));
  }
  await miSans.load();
  final String? root = Platform.environment['FLUTTER_ROOT'];
  final File icons = File(
    '${root ?? ''}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!icons.existsSync()) {
    throw StateError('MaterialIcons font not found at ${icons.path}');
  }
  final Uint8List bytes = await icons.readAsBytes();
  final FontLoader material = FontLoader('MaterialIcons')
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await material.load();
}

void main() {
  setUpAll(_loadScreenshotFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('phone music and navigation bars float separately', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    final _Engine engine = _Engine();
    addTearDown(engine.dispose);
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine)
      ..legacyBackground = LegacyBackgroundMode.nowPlayingStatic;
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(state, brightness: Brightness.dark));
    await tester.pump();
    expect(find.byType(LiquidGlassNavBar), findsOneWidget);
    expect(find.byType(LiquidGlassPanel), findsOneWidget);

    state.playQueue(const <Track>[_first, _second]);
    await tester.pump();
    await tester.pump();

    expect(find.byType(LiquidGlassPanel), findsNWidgets(2));
    expect(find.byType(LegacyPlayerBar), findsOneWidget);
    final Rect music = tester.getRect(find.byType(LegacyPlayerBar));
    final Rect nav = tester.getRect(find.byType(LiquidGlassNavBar));
    expect(
      music.bottom,
      lessThanOrEqualTo(nav.top - LiquidGlassMetrics.barGap + 0.5),
    );
    expect(nav.bottom, closeTo(844 - 34, 1));
    expect(music.left, closeTo(12, 1));
    expect(nav.left, closeTo(12, 1));
    expect(nav.right, closeTo(390 - 12, 1));
    expect(
      tester.widget<FloatingDockInset>(find.byType(FloatingDockInset)).inset,
      closeTo(
        LegacyPlayerBar.contentHeight(compact: true) +
            LiquidGlassMetrics.barGap +
            LiquidGlassMetrics.navHeight +
            34 +
            LiquidGlassMetrics.contentGap,
        0.5,
      ),
    );

    expect(
      find.byKey(LiquidGlassNavBar.selectionKey),
      findsOneWidget,
      reason: 'the selected tab is its own refracting lens',
    );

    expect(
      Theme.of(tester.element(find.byType(LegacyShell))).brightness,
      Brightness.dark,
    );
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await _capture(tester, 'app-phone-dark');

    await tester.tap(find.text('搜索'));
    await tester.pump();
    expect(find.text('搜索歌曲、歌手或歌单。'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(find.text('配色'), findsOneWidget);
    expect(find.text('检查更新'), findsNothing);

    expect(state.playing, isTrue);
    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(state.playing, isFalse);
    expect(find.byTooltip('播放'), findsOneWidget);

    await tester.tap(find.byTooltip('下一首'));
    await tester.pump();
    expect(state.current?.id, '2');

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text('秒針を噛む'),
      ),
    );
    await tester.pump();
    expect(find.byType(NowPlayingPage), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('phone liquid glass is light when the theme is light', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    final _Engine engine = _Engine();
    addTearDown(engine.dispose);
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
    addTearDown(state.dispose);
    state
      ..legacyBackground = LegacyBackgroundMode.nowPlayingStatic
      ..playQueue(const <Track>[_first, _second]);
    await tester.pumpWidget(_app(state, brightness: Brightness.light));
    for (var frame = 0; frame < 24; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      Theme.of(tester.element(find.byType(LegacyShell))).brightness,
      Brightness.light,
    );
    expect(find.byType(LiquidGlassPanel), findsNWidgets(2));
    final Rect music = tester.getRect(find.byType(LegacyPlayerBar));
    final Rect nav = tester.getRect(find.byType(LiquidGlassNavBar));
    expect(
      music.bottom,
      lessThanOrEqualTo(nav.top - LiquidGlassMetrics.barGap + 0.5),
    );
    await _capture(tester, 'app-phone-light');
    if (state.playing) state.togglePlay();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop keeps one transport capsule and seek still works', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(const <Track>[_first, _second]);
    await tester.pumpWidget(_app(state, brightness: Brightness.light));
    await tester.pump();
    await _capture(tester, 'desktop-light');

    expect(find.byType(LiquidGlassNavBar), findsNothing);
    expect(find.byType(LiquidGlassPanel), findsOneWidget);
    expect(find.byType(LegacyThinSeekBar), findsOneWidget);
    expect(state.position, Duration.zero);

    await tester.drag(find.byType(LegacyThinSeekBar), const Offset(160, 0));
    await tester.pump();
    expect(state.position, greaterThan(Duration.zero));
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear glass bends a busy backdrop when Flutter GPU is on', (
    tester,
  ) async {
    await tester.runAsync(LiquidGlass.precache);
    for (final Brightness brightness in <Brightness>[
      Brightness.dark,
      Brightness.light,
    ]) {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      final _Engine engine = _Engine();
      addTearDown(engine.dispose);
      final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue(const <Track>[_first]);
      await tester.pumpWidget(_refractionApp(state, brightness: brightness));
      // The renderer paints its fallback until the GPU shaders are ready.
      for (var frame = 0; frame < 40; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      if (find.byType(FakeGlass).evaluate().isNotEmpty) {
        if (state.playing) state.togglePlay();
        await tester.pump();
        markTestSkipped(
          'Flutter GPU is off, so liquid_glass_renderer paints FakeGlass',
        );
        return;
      }
      expect(find.byType(FakeGlass), findsNothing);
      expect(find.byType(LiquidGlassPanel), findsNWidgets(2));
      final Rect music = tester.getRect(find.byType(LegacyPlayerBar));
      final Rect nav = tester.getRect(find.byType(LiquidGlassNavBar));
      expect(music.bottom, lessThan(nav.top));
      await _capture(
        tester,
        brightness == Brightness.dark
            ? 'diagnostic-circles-dark'
            : 'diagnostic-circles-light',
      );
      if (state.playing) state.togglePlay();
      await tester.pump();
    }
    addTearDown(tester.view.reset);
    expect(tester.takeException(), isNull);
  });
}

Widget _refractionApp(AppState state, {required Brightness brightness}) {
  final ThemeData theme = buildLegacyTheme(brightness: brightness);
  return MaterialApp(
    theme: theme,
    darkTheme: theme,
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    home: Scaffold(
      body: RepaintBoundary(
        key: const ValueKey<String>('chrome-shot'),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              painter: _BusyBackdropPainter(
                dark: brightness == Brightness.dark,
              ),
            ),
            Positioned(
              left: LiquidGlassMetrics.sideMargin,
              right: LiquidGlassMetrics.sideMargin,
              bottom: 34,
              child: LiquidGlassChrome(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    LiquidGlassPanel(
                      child: LegacyPlayerBar(
                        state: state,
                        compact: true,
                        framed: false,
                        onOpen: () {},
                      ),
                    ),
                    const SizedBox(height: LiquidGlassMetrics.barGap),
                    LiquidGlassPanel(
                      child: LiquidGlassNavBar(
                        selectedIndex: 0,
                        onDestinationSelected: (_) {},
                        destinations: const <LiquidGlassDestination>[
                          LiquidGlassDestination(
                            icon: Icons.home_outlined,
                            selectedIcon: Icons.home_rounded,
                            label: '主页',
                          ),
                          LiquidGlassDestination(
                            icon: Icons.search_outlined,
                            selectedIcon: Icons.search_rounded,
                            label: '搜索',
                          ),
                          LiquidGlassDestination(
                            icon: Icons.library_music_outlined,
                            selectedIcon: Icons.library_music_rounded,
                            label: '音乐库',
                          ),
                          LiquidGlassDestination(
                            icon: Icons.favorite_border_rounded,
                            selectedIcon: Icons.favorite_rounded,
                            label: '我喜欢',
                          ),
                          LiquidGlassDestination(
                            icon: Icons.settings_outlined,
                            selectedIcon: Icons.settings_rounded,
                            label: '设置',
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BusyBackdropPainter extends CustomPainter {
  const _BusyBackdropPainter({required this.dark});

  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color(0xFF1B1035),
            Color(0xFF0E4D5C),
            Color(0xFFB4334A),
            Color(0xFFE6B15A),
          ],
        ).createShader(rect),
    );
    final List<Color> inks = <Color>[
      const Color(0xFF7C5CFF),
      const Color(0xFF2EE6A6),
      const Color(0xFFFF5D8F),
      const Color(0xFF3D7EFF),
      const Color(0xFFFFC857),
    ];
    for (int i = 0; i < 18; i++) {
      final double x = size.width * ((i * 37) % 100) / 100;
      final double y = size.height * ((i * 53) % 100) / 100;
      canvas.drawCircle(
        Offset(x, y),
        28 + (i % 5) * 16,
        Paint()
          ..color = inks[i % inks.length].withValues(alpha: dark ? .85 : .7),
      );
    }
    for (int i = 0; i < 8; i++) {
      canvas.drawLine(
        Offset(0, size.height * i / 7),
        Offset(size.width, size.height * (i + 2) / 9),
        Paint()
          ..color = const Color(0x66FFFFFF)
          ..strokeWidth = 3,
      );
    }
  }

  @override
  bool shouldRepaint(_BusyBackdropPainter oldDelegate) =>
      oldDelegate.dark != dark;
}
