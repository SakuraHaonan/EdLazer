import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';

const Track _track = Track(
  id: 'route-fixture',
  title: 'Route fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric\n[00:10.00]Third lyric',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the shell hosts the player as a stable same-route overlay', (
    tester,
  ) async {
    final semanticsHandle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    state.playQueue(<Track>[_track]);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildLegacyTheme(),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump();
    final rootFinder = find.byKey(
      const ValueKey<String>('app-semantics-root'),
    );
    final rootBefore = tester.getSemantics(rootFinder);
    await tester.tap(find.byTooltip('歌词'));
    await tester.pump();
    final playerSlide = find
        .ancestor(
          of: find.byType(NowPlayingPage),
          matching: find.byType(SlideTransition),
        )
        .first;
    expect(
      tester.widget<SlideTransition>(playerSlide).position.value.dy,
      closeTo(1, .001),
      reason: 'the player must start below the window',
    );
    await tester.pump(const Duration(milliseconds: 100));
    final midY = tester
        .widget<SlideTransition>(playerSlide)
        .position
        .value
        .dy;
    expect(midY, greaterThan(0));
    expect(midY, lessThan(1));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-now-playing')),
      findsOneWidget,
    );
    expect(tester.getSemantics(rootFinder).id, rootBefore.id);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 380));
    expect(
      tester.widget<SlideTransition>(playerSlide).position.value.dy,
      closeTo(0, .001),
    );
    expect(tester.getSemantics(rootFinder).id, rootBefore.id);
    await tester.tap(find.byKey(const ValueKey<String>('desktop-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 340));
    await tester.pump();
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.getSemantics(rootFinder).id, rootBefore.id);
    expect(tester.takeException(), isNull);
    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    semanticsHandle.dispose();
  });
}
