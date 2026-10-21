import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
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

  testWidgets('the rebuilt route opens and closes the Apple player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track]);

    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openNowPlayingPage(context, state),
                child: const Text('打开播放器'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开播放器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-now-playing')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('desktop-seek-bar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('desktop-close')));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsNothing);
    expect(tester.takeException(), isNull);
  });
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
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(NowPlayingPage), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('desktop-now-playing')),
      findsOneWidget,
    );
    expect(tester.getSemantics(rootFinder).id, rootBefore.id);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 380));
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
