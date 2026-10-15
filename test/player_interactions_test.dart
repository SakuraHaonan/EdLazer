import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/lyric_selection.dart';
import 'package:lazer_nextgen/data/lyrics.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/screens/now_playing_page.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/screens/playlist_detail_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/theme/design_tokens.dart';
import 'package:lazer_nextgen/widgets/lyric_selection_toolbar.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _playlist = Playlist(
  id: '12',
  name: 'Playlist',
  trackIds: [],
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  final tracks = [
    for (var i = 1; i <= 100; i++)
      Track(
        id: '$i',
        title: 'Song $i',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(minutes: 2),
        coverSeed: i,
      ),
  ];
  @override
  Future<List<Track>> playlistTracks(String id) async => tracks;
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]Line $i',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]翻译 $i',
    ].join('\n'),
  );
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('diag/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

Future<dynamic> _backEvent(
  WidgetTester tester,
  String method, [
  double progress = 0,
]) async {
  final result = Completer<dynamic>();
  tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    SystemChannels.backGesture.codec.encodeMethodCall(
      MethodCall(method, {
        'touchOffset': [20.0 + 200 * progress, 400.0],
        'progress': progress,
        'swipeEdge': 0,
      }),
    ),
    (bytes) => result.complete(
      bytes == null
          ? null
          : SystemChannels.backGesture.codec.decodeEnvelope(bytes),
    ),
  );
  return result.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test(
    'selection toggles, extends from the surviving anchor and follows stable line keys',
    () {
      const lines = [
        LyricLine(Duration.zero, 'A', translation: '甲'),
        LyricLine(Duration(seconds: 1), ''),
        LyricLine(Duration(seconds: 2), 'B'),
        LyricLine(Duration(seconds: 3), 'C'),
      ];
      var selection = const LyricSelection().begin(lines, 0).extend(lines, 3);
      expect(selection.keys.length, 3);
      selection = selection.toggle(lines, 0);
      expect(selection.anchor, lyricSelectionKey(lines[2]));
      selection = selection.extend(lines, 3);
      expect(
        selection.text([
          const LyricLine(Duration(milliseconds: 500), ''),
          ...lines,
        ]),
        'B\nC',
      );
      expect(
        const LyricSelection().begin(lines, 0).all(lines).text(lines),
        'A\n甲\nB\nC',
      );
    },
  );

  testWidgets(
    'long hold drag selects inline, back clears selection, and changing tracks clears picks',
    (tester) async {
      final catalog = _Catalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      state.playQueue(catalog.tracks.take(2).toList());
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: AppColors.ivoryMedium,
                child: LyricViewport(state: state),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = state.position;
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Line 0')),
      );
      await tester.pump(const Duration(milliseconds: 550));
      await gesture.moveTo(tester.getCenter(find.text('Line 2')));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 3 行'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(state.position, before);
      await _capture(tester, key, 'inline_lyric_selection');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(LyricSelectionToolbar), findsNothing);
      await tester.longPress(find.text('Line 0'));
      await tester.pumpAndSettle();
      state.next();
      await tester.pumpAndSettle();
      expect(find.byType(LyricSelectionToolbar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'locator hides for visible or unrelated songs, fades out, and reappears after scrolling away',
    (tester) async {
      final catalog = _Catalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      state.playQueue([catalog.tracks[75]]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: PlaylistDetailView(state: state, playlist: _playlist),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(FloatingActionButton);
      final opacity = find
          .ancestor(of: button, matching: find.byType(AnimatedOpacity))
          .first;
      final fade = find
          .descendant(of: opacity, matching: find.byType(FadeTransition))
          .first;
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      await tester.tap(button);
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        tester.widget<FadeTransition>(fade).opacity.value,
        inExclusiveRange(0, 1),
      );
      await tester.pumpAndSettle();
      expect(find.text('Song 76'), findsOneWidget);
      expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
      final scroll = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      state.playQueue([
        const Track(
          id: '900',
          title: 'Outside',
          artist: '',
          album: '',
          duration: Duration(minutes: 2),
          coverSeed: 0,
        ),
      ]);
      await tester.pumpAndSettle();
      expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets('now playing rises on entry and descends on exit on $platform', (
      tester,
    ) async {
      final catalog = _Catalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      state.playQueue([catalog.tracks.first]);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: buildAppTheme().copyWith(platform: platform),
          home: const Scaffold(),
        ),
      );
      final route = NowPlayingRoute(state: state);
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final page = find.byType(NowPlayingPage);
      expect(tester.getTopLeft(page).dy, greaterThan(0));
      expect(tester.getTopLeft(page).dx, closeTo(0, .1));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(page).dy, closeTo(0, .1));
      if (platform == TargetPlatform.android) {
        expect(
          route.popGestureEnabled,
          true,
          reason:
              'first=${route.isFirst}, current=${route.isCurrent}, pop=${route.popDisposition}, status=${route.animation!.status}',
        );
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget.runtimeType.toString() ==
                '_PredictiveBackGestureDetector',
          ),
          findsWidgets,
        );
        expect(await _backEvent(tester, 'startBackGesture'), true);
        await _backEvent(tester, 'updateBackGestureProgress', .4);
        await tester.pump();
        await _backEvent(tester, 'cancelBackGesture', .4);
        await tester.pumpAndSettle();
        expect(page, findsOneWidget);
      }
      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getTopLeft(page).dy, greaterThan(0));
      expect(tester.getTopLeft(page).dx, closeTo(0, .1));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'compact playlist footer paints one surface through the home gesture area',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final catalog = _Catalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      state.playQueue([catalog.tracks.first]);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(bottom: 34),
              viewPadding: const EdgeInsets.only(bottom: 34),
            ),
            child: child!,
          ),
          home: RepaintBoundary(
            key: key,
            child: PlaylistDetailPage(playlist: _playlist, state: state),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byType(PlayerControlsBar));
      expect(bar.bottom, 844);
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int pixel(int x, int y) => bytes.getUint32((y * image.width + x) * 4);
        expect(pixel(195, 835), 0xfaf9f5ff);
        expect(pixel(195, bar.top.toInt() + 4), 0xfaf9f5ff);
        image.dispose();
      });
      await _capture(tester, key, 'playlist_footer_safe_area');
      expect(tester.takeException(), isNull);
    },
  );
}
