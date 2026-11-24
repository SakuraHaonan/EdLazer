import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
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

void main() {
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
    final AppState state = AppState(catalog: _Catalog(), audioEngine: engine);
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

    final Iterable<DecoratedBox> lenses = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(LiquidGlassNavBar),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(lenses, isNotEmpty);
    for (final DecoratedBox lens in lenses) {
      final Decoration decoration = lens.decoration;
      expect(decoration, isA<BoxDecoration>());
      expect((decoration as BoxDecoration).border, isNull);
    }

    expect(
      Theme.of(tester.element(find.byType(LegacyShell))).brightness,
      Brightness.dark,
    );
    await _capture(tester, 'phone-dark');

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
    state.playQueue(const <Track>[_first, _second]);
    await tester.pumpWidget(_app(state, brightness: Brightness.light));
    await tester.pump();
    await tester.pump();
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
    await _capture(tester, 'phone-light');
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
}
