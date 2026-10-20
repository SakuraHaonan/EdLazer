import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoSwitch;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/interaction/app_haptics.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/scrolling/scroll_motion.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/interaction_feedback.dart';
import 'package:lazer_nextgen/widgets/lyric_image_dialog.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';

const _track = Track(
  id: 'fixture',
  title: '春の歌',
  artist: 'Artist / Singer',
  album: 'Album',
  duration: Duration(minutes: 2),
  coverSeed: 1,
);
const _next = Track(
  id: 'next',
  title: 'Next',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 2),
  coverSeed: 2,
);

class _Catalog extends Catalog {
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(Track track) async => 'fixture';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00]First line\n[00:01]Second line\n[00:02]Third line',
    tlyric: '[00:00]第一行\n[00:01]第二行\n[00:02]第三行',
  );
}

class _Engine implements AudioEngine {
  double volume = 1;
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
    position = Duration.zero;
    volume = 1;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
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

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  testWidgets(
    'blank taps and drags stay silent; actual controls use iOS intensity',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHaptics.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AppHaptics.channel,
          null,
        ),
      );
      final state = AppState(catalog: _Catalog())..hapticIntensity = .35;
      addTearDown(state.dispose);
      await tester.pumpWidget(
        InteractionFeedback(
          state: state,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  const SizedBox(
                    key: ValueKey('blank'),
                    width: 300,
                    height: 200,
                    child: ColoredBox(color: Colors.transparent),
                  ),
                  AccessibleIconButton(
                    tooltip: '操作',
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () {},
                  ),
                  const AccessibleIconButton(
                    tooltip: '禁用',
                    icon: Icon(Icons.stop),
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('blank')));
      await tester.drag(
        find.byKey(const ValueKey('blank')),
        const Offset(0, 80),
      );
      expect(calls, isEmpty);
      await tester.tap(find.byTooltip('操作'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single.arguments, {'intensity': .35, 'kind': 'tap'});
      await tester.tap(find.byTooltip('禁用'));
      await state.setHapticsEnabled(false);
      await tester.tap(find.byTooltip('操作'));
      expect(calls, hasLength(1));
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'seek notches require movement; endpoints retain stronger feedback',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHaptics.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AppHaptics.channel,
          null,
        ),
      );
      var now = DateTime(2026);
      final haptics = AppHaptics(now: () => now);
      final detents = SeekDetents();
      expect(detents.update(.5), false);
      detents.begin(.1);
      expect(detents.update(.104), false);
      expect(detents.update(.12), true);
      await haptics.pulse(enabled: true, intensity: .8, detent: true);
      expect(detents.update(.12), false);
      now = now.add(const Duration(milliseconds: 10));
      await haptics.pulse(enabled: true, intensity: .8, detent: true);
      expect(calls, hasLength(1));
      expect((calls.first.arguments as Map)['intensity'], closeTo(.44, 1e-8));
      expect(detents.update(1), true);
      await haptics.pulse(
        enabled: true,
        intensity: .8,
        detent: true,
        boundary: true,
      );
      expect((calls.last.arguments as Map)['kind'], 'boundary');
      expect((calls.last.arguments as Map)['intensity'], .8);
      detents.end();
      expect(detents.update(.9), false);
      await haptics.pulse(enabled: true, intensity: 0);
      expect(calls, hasLength(2));
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'iOS intensity is saved and switches are rendered by the app',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: Scaffold(body: LegacySettingsPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      final intensity = find.byWidgetPredicate(
        (w) => w is AccessibleSlider && w.semanticLabel == '震动强度',
      );
      await tester.ensureVisible(intensity);
      await tester.pumpAndSettle();
      final slider = find.descendant(
        of: intensity,
        matching: find.byType(Slider),
      );
      await tester.drag(slider, const Offset(90, 0));
      await tester.pumpAndSettle();
      expect(state.hapticIntensity, greaterThan(.5));
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'lazer_haptic_intensity',
        ),
        state.hapticIntensity,
      );
      expect(find.byType(CupertinoSwitch), findsNothing);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets(
    'setting sliders click through detents and stop when disabled',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        AppHaptics.channel,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          AppHaptics.channel,
          null,
        ),
      );
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        InteractionFeedback(
          state: state,
          child: MaterialApp(
            theme: buildLegacyTheme(),
            home: Scaffold(body: LegacySettingsPage(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final slider = find.byWidgetPredicate(
        (w) => w is AccessibleSlider && w.semanticLabel == '歌词控件自动隐藏',
      );
      expect(tester.widget<AccessibleSlider>(slider).detentFeedback, isTrue);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      calls.clear();
      final track = tester.getRect(
        find.descendant(of: slider, matching: find.byType(Slider)),
      );
      final gesture = await tester.startGesture(
        Offset(track.left + 300, track.center.dy),
      );
      await tester.pump();
      for (var dx = 250.0; dx >= 0; dx -= 25) {
        await gesture.moveTo(Offset(track.left + dx, track.center.dy));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(calls, isNotEmpty);
      expect(state.lyricControlsSeconds, 1);
      expect(
        calls.map((call) => (call.arguments as Map)['kind']),
        everyElement(anyOf(equals('detent'), equals('boundary'))),
      );
      expect(
        calls.map((call) => (call.arguments as Map)['kind']),
        contains('detent'),
      );
      expect(
        calls.map((call) => (call.arguments as Map)['kind']),
        contains('boundary'),
      );
      await state.setHapticsEnabled(false);
      calls.clear();
      final back = await tester.startGesture(
        Offset(track.left + 5, track.center.dy),
      );
      await tester.pump();
      for (var dx = 50.0; dx <= 300; dx += 25) {
        await back.moveTo(Offset(track.left + dx, track.center.dy));
        await tester.pump();
      }
      await back.up();
      await tester.pumpAndSettle();
      expect(state.lyricControlsSeconds, greaterThan(1));
      expect(calls, isEmpty);
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  test('SliderDetents quantizes by divisions and stays silent when idle', () {
    final detents = SliderDetents(min: 1, max: 10, steps: 18);
    expect(detents.update(9), false);
    detents.begin(3.5);
    expect(detents.update(3.5), false);
    expect(detents.update(4), true);
    expect(detents.update(4.02), false);
    detents.end();
    expect(detents.update(5), false);
    final open = SliderDetents(min: 0, max: 1);
    open.begin(0);
    expect(open.update(0.004), false);
    expect(open.update(0.01), true);
  });

  test(
    'volume changes reach the engine, survive tracks and restore the unmuted level',
    () async {
      final engine = _Engine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      await state.setVolume(.7);
      // Dragging the bar down to .4 is what the control does on onChanged.
      await state.setVolume(.4);
      final volume = state.volume;
      expect(volume, inExclusiveRange(0, .7));
      expect(engine.volume, volume);
      state.playQueue([_track, _next]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(engine.volume, volume);
      state.next();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        engine.volume,
        volume,
        reason: 'setUrl reset must not restore full volume',
      );
      await state.toggleMute();
      expect(engine.volume, 0);
      final restoredEngine = _Engine();
      final restored = AppState(
        catalog: _Catalog(),
        audioEngine: restoredEngine,
      );
      addTearDown(restored.dispose);
      await restored.bootstrap();
      expect(restored.volume, 0);
      expect(restoredEngine.volume, 0);
      await restored.toggleMute();
      expect(restored.volume, volume);
      expect(restoredEngine.volume, volume);
      await state.setVolume(4);
      expect(engine.volume, 1);
      await state.setVolume(-1);
      expect(engine.volume, 0);
      state.pause();
    },
  );

  testWidgets(
    'plain LRC follows within 5ms and eases color with scale across a line boundary',
    (tester) async {
      final engine = _Engine();
      final state = AppState(catalog: _Catalog(), audioEngine: engine);
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      ColorFilter color(int i) => tester
          .widget<ColorFiltered>(find.byKey(ValueKey('lyric-color-$i')))
          .colorFilter;
      double scale(int i) => tester
          .widget<Transform>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('lyric-blur-$i')),
                  matching: find.byType(Transform),
                )
                .first,
          )
          .transform
          .storage[0];
      final oldColor = color(0);
      final nextColor = color(1);
      engine.position = const Duration(milliseconds: 1001);
      await tester.pump(const Duration(milliseconds: 5));
      expect(
        state.position,
        Duration.zero,
        reason: 'transport has not reached its next 100ms tick',
      );
      expect(
        color(0),
        oldColor,
        reason: 'outgoing color stays continuous at retarget',
      );
      expect(color(1), nextColor);
      await tester.pump(const Duration(milliseconds: 16));
      final firstScale = scale(0);
      await tester.pump(const Duration(milliseconds: 16));
      final secondScale = scale(0);
      expect(secondScale, lessThan(firstScale));
      expect(
        1 - firstScale,
        lessThan(firstScale - secondScale),
        reason: 'the spring accelerates nonlinearly',
      );
      expect(color(0), isNot(oldColor));
      expect(color(1), isNot(nextColor));
      expect(
        color(0),
        isNot(nextColor),
        reason: 'outgoing line has not snapped to grey',
      );
      await tester.pumpAndSettle();
      expect(color(0), nextColor);
      expect(color(1), oldColor);
      state.pause();
      await tester.pumpAndSettle();
      expect(
        color(0),
        nextColor,
        reason: 'pausing preserves the inactive tone',
      );
      expect(color(1), oldColor);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'successive wheel impulses accumulate and opposite impulses brake momentum',
    () {
      final first = ScrollMotion.addWheelImpulse(0, 50);
      final second = ScrollMotion.addWheelImpulse(first, 50);
      expect(second, first * 2);
      expect(
        ScrollMotion.addWheelImpulse(second, -25),
        inExclusiveRange(0, second),
      );
      expect(ScrollMotion.carriedVelocity(2000), 1300);
    },
  );

  testWidgets(
    'image entry precedes copy and exports only the selected lyrics',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(brightness: Brightness.dark),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.longPress(find.text('First line'));
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byTooltip('生成歌词图片')).dx,
        lessThan(tester.getCenter(find.byTooltip('复制所选歌词')).dx),
      );
      await tester.tap(find.byTooltip('生成歌词图片'));
      await tester.pumpAndSettle();
      final card = tester.widget<LyricImageCard>(find.byType(LyricImageCard));
      expect(card.track.id, _track.id);
      expect(card.lines.map((line) => line.text), ['First line']);
      expect(card.lines.single.translation, '第一行');
      final context = tester.element(find.byType(LyricImageCard));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('复制所选歌词'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'long lyric PNG includes offscreen content in ${brightness.name} theme',
      (tester) async {
        tester.view.physicalSize = const Size(390, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final lines = [
          for (var i = 0; i < 30; i++)
            LyricLine(
              Duration(seconds: i),
              'Lyrics line $i',
              translation: '第 $i 行翻译',
            ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: buildLegacyTheme(brightness: brightness),
            home: Scaffold(
              body: LyricImageDialog(track: _track, lines: lines),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find
              .ancestor(
                of: find.byType(LyricImageCard),
                matching: find.byType(RepaintBoundary),
              )
              .first,
        );
        expect(boundary.size.height, greaterThan(2500));
        await tester.runAsync(() async {
          final png = await captureLyricImage(boundary);
          final codec = await ui.instantiateImageCodec(png);
          final frame = await codec.getNextFrame();
          expect(frame.image.width, 1080);
          expect(frame.image.height, greaterThan(7500));
          final raw = await frame.image.toByteData();
          final background = buildLegacyTheme(
            brightness: brightness,
          ).colorScheme.surfaceContainerLowest;
          final rgba = raw!.buffer.asUint8List();
          final end = rgba.length - 4;
          expect(rgba.sublist(0, 4), [
            (background.r * 255).round(),
            (background.g * 255).round(),
            (background.b * 255).round(),
            255,
          ]);
          expect(
            rgba.sublist(end),
            rgba.sublist(0, 4),
            reason: 'offscreen end of the sheet is painted, opaque and uncut',
          );
          if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
            await Directory('diag').create(recursive: true);
            await File(
              'diag/lyric_image_${brightness.name}.png',
            ).writeAsBytes(png);
          }
          frame.image.dispose();
          codec.dispose();
        });
        expect(tester.takeException(), isNull);
      },
    );
  }
}
