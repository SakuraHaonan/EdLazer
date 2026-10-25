import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';
import 'package:lazer_nextgen/widgets/haptic_seek_slider.dart';

const Track _seekTrack = Track(
  id: 'tv-seek',
  title: 'Song',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 1),
  coverSeed: 1,
);

class _SeekCatalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => 'fixture';
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '');
}

class _SeekEngine implements AudioEngine {
  @override
  bool active = false;
  @override
  Duration position = Duration.zero;
  @override
  Duration? get duration => _seekTrack.duration;
  @override
  Stream<void> get completed => const Stream<void>.empty();
  @override
  Future<void> setUrl(String url) async {
    active = true;
    position = Duration.zero;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration value) async {
    position = value;
  }

  @override
  Future<void> stop() async => active = false;
  @override
  void dispose() {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('tv input', () {
    testWidgets('a tap target takes focus and activates with Select', (
      tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      int taps = 0;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: TvTapTarget(
                  focusNode: node,
                  onTap: () => taps++,
                  child: const SizedBox(
                    width: 120,
                    height: 48,
                    child: Center(child: Text('播放')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(TvFocusOutline), findsNothing);

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);
      expect(find.byType(TvFocusOutline), findsOneWidget);

      // A remote's centre button arrives as `select`.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap target stays inert off the television', (tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        TvScope(
          active: false,
          child: MaterialApp(
            home: Scaffold(
              body: TvTapTarget(
                focusNode: node,
                onTap: () {},
                child: const Text('播放'),
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
      expect(find.byType(TvFocusOutline), findsNothing);
    });

    testWidgets('the television alone gets overscan-safe insets', (
      tester,
    ) async {
      EdgeInsets? active;
      EdgeInsets? inactive;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: Builder(
            builder: (BuildContext context) {
              active = tvSafeInsets(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        TvScope(
          active: false,
          child: Builder(
            builder: (BuildContext context) {
              inactive = tvSafeInsets(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(active, const EdgeInsets.fromLTRB(24, 16, 24, 16));
      expect(inactive, EdgeInsets.zero);
    });

    testWidgets('left and right scrub the player seek rail', (tester) async {
      final List<double> seeks = <double>[];
      int committed = 0;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: LegacyThinSeekBar(
                    progress: .5,
                    onSeek: seeks.add,
                    onSeekFinished: () => committed++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final FocusNode node = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(LegacyThinSeekBar),
                matching: find.byType(Semantics),
              )
              .last,
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(
        node.canRequestFocus,
        isTrue,
        reason:
            'node=${node.debugLabel} primary=${FocusManager.instance.primaryFocus}',
      );
      expect(node.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks.last, closeTo(.52, 1e-9));
      expect(committed, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(seeks.last, closeTo(.5, 1e-9));
      expect(committed, 2);

      // The pinned preview releases after the short commit window.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('up and down leave the seek rail instead of scrubbing', (
      tester,
    ) async {
      final AppState state = AppState(
        catalog: _SeekCatalog(),
        audioEngine: _SeekEngine(),
      );
      addTearDown(state.dispose);
      state.playQueue(const <Track>[_seekTrack]);
      await tester.pump();
      state.seek(.5);
      expect(state.progress, closeTo(.5, 1e-9));

      final FocusNode above = FocusNode();
      final FocusNode below = FocusNode();
      addTearDown(above.dispose);
      addTearDown(below.dispose);
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  TextButton(
                    focusNode: above,
                    onPressed: () {},
                    child: const Text('above'),
                  ),
                  SizedBox(
                    width: 320,
                    child: HapticSeekSlider(state: state),
                  ),
                  TextButton(
                    focusNode: below,
                    onPressed: () {},
                    child: const Text('below'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final FocusNode rail = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(HapticSeekSlider),
                matching: find.byType(Stack),
              )
              .first,
        ),
      );
      rail.requestFocus();
      await tester.pump();
      expect(rail.hasFocus, isTrue);

      // Down and up move the remote's focus out of the rail. The Material
      // slider would otherwise spend them on the value.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(below.hasFocus, isTrue);
      expect(state.progress, closeTo(.5, 1e-9));

      // Up first returns to the rail (Flutter remembers the down traversal),
      // then leaves it for the row above.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(rail.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(above.hasFocus, isTrue);
      expect(state.progress, closeTo(.5, 1e-9));

      // Left and right still scrub the song.
      rail.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(state.progress, closeTo(.48, 1e-9));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(state.progress, closeTo(.5, 1e-9));
      state.pause();
      expect(tester.takeException(), isNull);
    });

    test('overlay panels close in stack order', () {
      final TvOverlayStack stack = TvOverlayStack.instance;
      final List<String> closed = <String>[];
      void first() => closed.add('first');
      void second() => closed.add('second');
      stack.push(first);
      stack.push(second);
      expect(stack.hasOpen, isTrue);
      expect(stack.closeTop(), isTrue);
      expect(closed, <String>['second']);
      expect(stack.closeTop(), isTrue);
      expect(closed, <String>['second', 'first']);
      expect(stack.closeTop(), isFalse);
      expect(stack.hasOpen, isFalse);
    });
  });

  group('android tv packaging', () {
    test('the manifest is a Leanback launcher with a banner', () {
      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android.software.leanback'));
      expect(manifest, contains('android.hardware.touchscreen'));
      expect(manifest, contains('android:required="false"'));
      expect(manifest, contains('LEANBACK_LAUNCHER'));
      expect(manifest, contains('android:banner="@drawable/tv_banner"'));
      expect(
        File(
          'android/app/src/main/res/drawable-xhdpi/tv_banner.png',
        ).existsSync(),
        isTrue,
        reason: 'the launcher banner must ship with the APK',
      );
    });
  });
}
