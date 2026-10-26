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
import 'package:lazer_nextgen/navigation/pull_down_to_close.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const Track _track = Track(
  id: 'pull-down-fixture',
  title: 'Pull down fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Size _phone = Size(390, 844);

/// Records what the strip reports, standing in for the shell or a route.
class _Host implements PlayerPullDown {
  bool allowed = true;
  bool started = false;
  bool ended = false;
  double progress = 0;
  double velocity = 0;

  @override
  bool get canStart => allowed;

  @override
  void startPull() => started = true;

  @override
  void updatePull(double value) => progress = value;

  @override
  void endPull(double value) {
    ended = true;
    velocity = value;
  }
}

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric\n[00:10.00]Third lyric',
  );
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

/// The player's presentation, which the pull drives: 0 is open, 1 is gone.
double _slide(WidgetTester tester) => tester
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

Future<void> _openPlayer(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  await state.setLegacyBackground(LegacyBackgroundMode.off);
  state.playQueue(const <Track>[_track]);
  await tester.pumpWidget(_app(LegacyShell(state: state)));
  await tester.pump(const Duration(milliseconds: 120));

  await tester.tap(
    find.descendant(
      of: find.byType(LegacyPlayerBar),
      matching: find.text(_track.title),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 360));
  expect(find.byType(NowPlayingPage), findsOneWidget);
  expect(find.byType(PlayerPullDownRegion), findsOneWidget);
}

/// A finger drag slow enough that the release is judged by distance, not by
/// the fling velocity.
Future<void> _slowDrag(
  WidgetTester tester,
  Offset from,
  Offset total, {
  int steps = 10,
}) async {
  final TestGesture gesture = await tester.startGesture(from);
  await tester.pump(const Duration(milliseconds: 40));
  for (int i = 0; i < steps; i++) {
    await gesture.moveBy(total / steps.toDouble());
    await tester.pump(const Duration(milliseconds: 40));
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a drag down the upper half pulls the player off screen', (
    tester,
  ) async {
    await _openPlayer(tester);
    expect(_slide(tester), 0);

    // 844 / 2 = 422: the strip only covers the upper half of the window.
    final TestGesture gesture = await tester.startGesture(
      const Offset(195, 160),
    );
    await tester.pump(const Duration(milliseconds: 40));
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(
      _slide(tester),
      closeTo(400 / _phone.height, .01),
      reason: 'the player should follow the finger one to one',
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a short pull springs back and keeps the header tappable', (
    tester,
  ) async {
    await _openPlayer(tester);

    await _slowDrag(tester, const Offset(195, 160), const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(_slide(tester), 0, reason: 'a short pull returns to the open state');

    // The strip floats above the header, so its buttons must keep working.
    await tester.tap(find.byTooltip('\u8fd4\u56de'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a drag that starts below the upper half leaves the player', (
    tester,
  ) async {
    await _openPlayer(tester);

    await _slowDrag(tester, const Offset(195, 470), const Offset(0, 240));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(_slide(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an upward drag scrolls instead of dismissing', (tester) async {
    await _openPlayer(tester);

    await _slowDrag(tester, const Offset(195, 220), const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(_slide(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the strip outranks a scroll view below it, downwards only', (
    tester,
  ) async {
    final _Host host = _Host();
    double scrolled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (DragUpdateDetails details) =>
                      scrolled += details.delta.dy,
                  child: const SizedBox.expand(),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 300,
                child: PlayerPullDownRegion(pullDown: host, travel: 600),
              ),
            ],
          ),
        ),
      ),
    );

    // Downward inside the strip: the player claims it, the scroll view does
    // not move even though the finger is over it.
    await _slowDrag(tester, const Offset(200, 100), const Offset(0, 120));
    expect(host.started, isTrue);
    expect(host.progress, closeTo(120 / 600, .01));
    expect(host.ended, isTrue);
    expect(scrolled, 0);

    // Upward inside the strip: the pull never starts.
    host
      ..started = false
      ..ended = false
      ..progress = 0;
    scrolled = 0;
    await _slowDrag(tester, const Offset(200, 100), const Offset(0, -120));
    expect(host.started, isFalse);
    expect(host.progress, 0);
    expect(scrolled, lessThan(0));

    // Downward below the strip: the scroll view keeps it.
    scrolled = 0;
    await _slowDrag(tester, const Offset(200, 400), const Offset(0, 120));
    expect(host.started, isFalse);
    expect(scrolled, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the desktop presentation never arms the gesture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    state.playQueue(const <Track>[_track]);
    await tester.pumpWidget(_app(LegacyShell(state: state)));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(find.byType(PlayerPullDownRegion), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
