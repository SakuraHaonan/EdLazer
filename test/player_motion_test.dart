import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/motion/ed_motion.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const Track _track = Track(
  id: 'motion-fixture',
  title: 'Motion fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the player sheet tracks the shared spring', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    // The browse backdrop would repaint the window behind the player; the
    // motion assertions only care about the player's own offset.
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    /// How much of the window height the player still has to travel: 1 is
    /// fully below the window, 0 is fully presented.
    double remaining() => tester
        .widget<SlideTransition>(
          find
              .ancestor(
                of: find.byType(NowPlayingPage),
                matching: find.byType(SlideTransition),
              )
              .first,
        )
        .position
        .value
        .dy;

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    expect(remaining(), closeTo(1, .02), reason: 'it starts below the window');

    // A spring released from rest accelerates: the second slice of the
    // opening covers more of the window than the first. An ease-out does
    // the opposite, which is how this stays distinct from the old curve.
    await tester.pump(const Duration(milliseconds: 40));
    final double firstLeg = 1 - remaining();
    expect(firstLeg, closeTo(EdMotion.travelled(0.04), 0.08));

    await tester.pump(const Duration(milliseconds: 40));
    final double secondLeg = 1 - remaining() - firstLeg;
    expect(
      secondLeg,
      greaterThan(firstLeg),
      reason: 'the sheet is still accelerating at 80 ms',
    );
    expect(1 - remaining(), closeTo(EdMotion.travelled(0.08), 0.08));

    await tester.pump(const Duration(milliseconds: 500));
    expect(remaining(), closeTo(0, .01));

    await tester.tap(find.byKey(const ValueKey('desktop-close')));
    await tester.pump();
    expect(remaining(), closeTo(0, .02));

    await tester.pump(const Duration(milliseconds: 80));
    expect(
      remaining(),
      closeTo(EdMotion.travelled(0.08), 0.08),
      reason: 'the close is the same spring, run toward the bottom edge',
    );

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
