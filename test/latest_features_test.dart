import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/animation/lyric_word_motion.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/l10n/app_language.dart';
import 'package:lazer_nextgen/l10n/app_localizations.dart';
import 'package:lazer_nextgen/screens/now_playing_page.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/timed_lyric_text.dart';
import 'package:lazer_nextgen/widgets/lyric_selection_toolbar.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';

const _track = Track(
  id: '1',
  title: '设置',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 2),
  coverSeed: 1,
  translatedTitle: 'Translated title',
);

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00]First line\n[00:02]Second line\n[00:04]Third line',
    tlyric: '[00:00]第一行\n[00:02]第二行\n[00:04]第三行',
  );
}

const _delegates = <LocalizationsDelegate<dynamic>>[
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
];

class _WordCatalog extends _Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => 'fixture';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    yrc: '[0,1000](0,500,0)最初(500,500,0)の行\n[1000,1500](1000,1500,0)次の行',
  );
}

class _Engine implements AudioEngine {
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => _track.duration;
  @override
  Stream<void> get completed => const Stream.empty();
  @override
  Future<void> setUrl(String url) async {
    active = true;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> stop() async {
    active = false;
  }

  @override
  void dispose() {}
}

Future<void> _snapshot(WidgetTester tester, GlobalKey key, String name) async {
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
    for (final locale in AppLocalizations.supportedLocales) {
      for (final delegate in _delegates) {
        await delegate.load(locale);
      }
    }
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  test(
    'Reference word emphasis matches keyframes executed from upstream TypeScript',
    () {
      final fixture =
          jsonDecode(
                File('test/fixtures/lyric_word_frames.json').readAsStringSync(),
              )
              as Map;
      for (final sample in fixture['cases'] as List) {
        final motion = LyricWordMotion.emphasized(
          (sample['elapsed'] as num).toDouble(),
          (sample['duration'] as num).toDouble(),
          sample['character'] as int,
          sample['count'] as int,
          last: sample['last'] as bool,
        );
        // Upstream rounds the CSS matrix to four decimals.
        expect(motion.scale, closeTo(sample['scale'] as num, .000051));
        expect(motion.xEm, closeTo(sample['x'] as num, 1e-6));
        expect(motion.yEm, closeTo(sample['y'] as num, 1e-6));
        expect(motion.glow, closeTo(sample['glow'] as num, 1e-6));
        expect(motion.glowRadiusEm, closeTo(sample['radius'] as num, 1e-8));
      }
      expect(LyricWordMotion.maskBoundary(250, 500, 120), 60);
      expect(LyricWordMotion.ordinary(-10, 300).yEm, closeTo(0, 1e-10));
      expect(LyricWordMotion.ordinary(1000, 300).yEm, closeTo(-.05, 1e-10));
    },
  );
  test(
    'all four catalogues have matching keys and resolve scripts and templates',
    () async {
      final catalogues = <AppLocalizations>[];
      for (final locale in AppLocalizations.supportedLocales) {
        catalogues.add(await AppLocalizations.delegate.load(locale));
      }
      for (final catalogue in catalogues) {
        expect(
          catalogue.messages.keys.toSet(),
          catalogues.first.messages.keys.toSet(),
        );
        expect(catalogue.messages.values.every((s) => s.isNotEmpty), true);
      }
      expect(catalogues[1].text('搜索'), '搜尋');
      expect(catalogues[2].text('播放队列 · 16 首'), '再生キュー · 16 曲');
      expect(catalogues[3].text('播放队列 · 16 首'), 'Play queue · 16 songs');
      expect(
        catalogues[3].text('将「設定」的封面保存在设备中。'),
        'Save the artwork for “設定” to this device.',
      );
      expect(
        AppLocalizations.resolve(const Locale('zh', 'TW')).scriptCode,
        'Hant',
      );
      expect(
        AppLocalizations.resolve(const Locale('zh', 'CN')).scriptCode,
        'Hans',
      );
      expect(AppLocalizations.resolve(const Locale('fr')).languageCode, 'en');
    },
  );
  testWidgets(
    'language changes from settings immediately and persists; music titles stay original',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            locale: state.language.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: _delegates,
            localeListResolutionCallback: (locales, _) =>
                AppLocalizations.resolve(locales?.firstOrNull),
            home: PlayerPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings').first);
      await tester.pumpAndSettle();
      final dropdown = find.byType(DropdownButtonFormField<AppLanguage>);
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('日本語').last);
      await tester.pumpAndSettle();
      expect(state.language, AppLanguage.japanese);
      expect(find.text('表示言語'), findsOneWidget);
      expect(find.text('スクロール慣性'), findsOneWidget);
      expect(
        find.text('设置'),
        findsOneWidget,
        reason: 'server title is never passed through the UI catalogue',
      );
      expect(
        (await SharedPreferences.getInstance()).getString('lazer_language'),
        'ja',
      );
      final restored = AppState(catalog: _Catalog());
      addTearDown(restored.dispose);
      await tester.runAsync(restored.bootstrap);
      expect(restored.language, AppLanguage.japanese);
      expect(restored.scrollRetention, .90);
    },
  );
  testWidgets(
    'long press selects multiple lines and copies originals plus translations in order',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: NowPlayingPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('歌词'));
      await tester.pumpAndSettle();
      final before = state.position;
      await tester.longPress(find.text('First line'));
      await tester.pumpAndSettle();
      expect(state.position, before, reason: 'long press does not seek');
      expect(find.byType(LyricSelectionToolbar), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text('Third line'));
      await tester.pump();
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byTooltip('复制所选歌词'));
      await tester.pump();
      expect(clipboard, 'First line\n第一行\nThird line\n第三行');
      await tester.pump(const Duration(seconds: 4));
      expect(find.byType(LyricSelectionToolbar), findsOneWidget);
      await tester.tap(find.byTooltip('全选'));
      await tester.pump();
      expect(find.text('已选择 3 行'), findsOneWidget);
      expect(find.byTooltip('复制所选歌词'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-0')))
            .enabled,
        false,
      );
      await tester.pump(const Duration(milliseconds: 2300));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-1')))
            .enabled,
        true,
      );
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-0')))
            .enabled,
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'desktop cover fills the rail; queue includes artwork and opens directly from footer',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      final tracks = [
        for (var i = 0; i < 16; i++)
          Track(
            id: '$i',
            title: 'Song $i',
            artist: 'Artist $i',
            album: 'Album',
            duration: const Duration(minutes: 2),
            coverSeed: i,
          ),
      ];
      state.playQueue(tracks, startIndex: 8);
      final screenshot = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: screenshot,
          child: MaterialApp(
            theme: buildAppTheme(),
            home: NowPlayingPage(state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final art = find.byType(PlateArt).first;
      expect(tester.getSize(art).width, closeTo(1100 * .28, .01));
      await tester.tap(find.byTooltip('播放队列'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      final list = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(ListView),
      );
      expect(
        find.descendant(of: list, matching: find.byType(PlateArt)),
        findsWidgets,
      );
      expect(find.text('Artist 8'), findsWidgets);
      expect(tester.getSize(list).width, lessThanOrEqualTo(580));
      await _snapshot(tester, screenshot, 'ui_queue_latest');
      await tester.tap(find.text('Song 9'));
      await tester.pumpAndSettle();
      expect(state.current?.id, '9');
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: PlayerPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('播放队列 · 16 首'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(NowPlayingPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'settings marker rises on entry, descends on exit, and navigation surfaces are square',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: PlayerPage(state: state),
        ),
      );
      await tester.tap(find.text('设置'));
      await tester.pump();
      final marker = find.byKey(const ValueKey('settings-selection-marker'));
      final slide = find
          .ancestor(of: marker, matching: find.byType(SlideTransition))
          .first;
      expect(tester.widget<SlideTransition>(slide).position.value.dy, 1);
      await tester.pump(const Duration(milliseconds: 100));
      final midway = tester.widget<SlideTransition>(slide).position.value.dy;
      expect(midway, inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(tester.widget<SlideTransition>(slide).position.value.dy, 0);
      final nav = find
          .ancestor(of: find.text('设置').first, matching: find.byType(InkWell))
          .first;
      expect(tester.widget<InkWell>(nav).borderRadius, BorderRadius.zero);
      await tester.tap(find.text('主页'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester.widget<SlideTransition>(slide).position.value.dy,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(marker, findsNothing);
    },
  );
  testWidgets(
    'word lines follow the engine clock between transport ticks and repaint paused seeks',
    (tester) async {
      final engine = _Engine();
      final state = AppState(catalog: _WordCatalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state.position, Duration.zero);
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-0')))
            .enabled,
        false,
      );
      engine.position = const Duration(milliseconds: 1200);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump();
      expect(
        state.position,
        Duration.zero,
        reason: 'the next 100ms transport tick has not fired',
      );
      expect(
        tester
            .widgetList<TimedLyricText>(find.byType(TimedLyricText))
            .map((line) => line.active),
        [false, true],
        reason:
            'word highlighting changes immediately; spatial blur eases as the row moves',
      );
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-1')))
            .enabled,
        true,
        reason: 'the incoming row must not snap from blurred to clear',
      );
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-1')))
            .enabled,
        false,
      );
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-0')))
            .enabled,
        true,
      );
      state.pause();
      state.seek(750 / 120000);
      await tester.pump();
      expect(state.precisePosition, const Duration(milliseconds: 750));
      expect(
        tester
            .widgetList<TimedLyricText>(find.byType(TimedLyricText))
            .map((line) => line.active),
        [true, false],
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ImageFiltered>(find.byKey(const ValueKey('lyric-blur-0')))
            .enabled,
        false,
      );
      expect(find.byType(TimedLyricText), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'word painting preserves wrapping, graphemes, semantics and deterministic seeking',
    (tester) async {
      final repaint = ValueNotifier(0);
      addTearDown(repaint.dispose);
      const line = LyricLine(
        Duration.zero,
        '春🌸の Hello world ',
        words: [
          LyricWord(Duration.zero, Duration(milliseconds: 1600), '春🌸の '),
          LyricWord(
            Duration(milliseconds: 1600),
            Duration(milliseconds: 400),
            'Hello ',
          ),
          LyricWord(
            Duration(milliseconds: 2000),
            Duration(milliseconds: 1800),
            'world ',
          ),
        ],
      );
      var position = Duration.zero;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: key,
                child: ColoredBox(
                  color: const Color(0xfff0eee6),
                  child: SizedBox(
                    width: 150,
                    child: TimedLyricText(
                      line: line,
                      style: const TextStyle(
                        fontFamily: 'MiSans',
                        fontSize: 22,
                        height: 1.5,
                        color: Colors.black,
                      ),
                      active: true,
                      position: () => position,
                      repaint: repaint,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(TimedLyricText)).height,
        greaterThan(33),
      );
      Future<Uint8List> pixels() async => (await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        return bytes!.buffer.asUint8List();
      }))!;
      final before = await pixels();
      position = const Duration(milliseconds: 2500);
      repaint.value++;
      await tester.pump();
      final after = await pixels();
      await _snapshot(tester, key, 'ui_word_lyrics_latest');
      expect(after, isNot(orderedEquals(before)));
      position = Duration.zero;
      repaint.value++;
      await tester.pump();
      expect(await pixels(), orderedEquals(before));
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel(line.text), findsOneWidget);
    },
  );
}
