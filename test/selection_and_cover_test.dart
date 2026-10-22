import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_now_playing.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/legacy/legacy_widgets.dart';
import 'package:lazer_nextgen/lyrics/viewport.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'selection-fixture',
  title: 'Selection fixture',
  artist: 'Test',
  album: 'Test',
  duration: Duration(minutes: 2),
  coverSeed: 1,
  coverUrl: 'https://example.invalid/cover.jpg',
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 20; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]歌词 $i',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 20; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]翻译 $i',
    ].join('\n'),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'long-press selection uses bright white and keeps unselected alpha',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue(<Track>[_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();

      double opacity(String key) =>
          tester.widget<Opacity>(find.byKey(ValueKey<String>(key))).opacity;
      ColorFilter tone(int index) => tester
          .widget<ColorFiltered>(
            find.byKey(ValueKey<String>('lyric-color-$index')),
          )
          .colorFilter;

      final activeBefore = opacity('lyric-bright-0');
      final inactiveBefore = opacity('lyric-bright-2');
      final translationBefore = opacity('lyric-translation-bright-1');

      await tester.longPress(find.text('歌词 1'));
      await tester.pumpAndSettle();

      expect(
        tone(1),
        equals(ColorFilter.mode(Colors.white, BlendMode.srcIn)),
        reason: 'the selection highlight is plain bright white',
      );
      expect(opacity('lyric-bright-1'), closeTo(1, .001));
      expect(
        opacity('lyric-translation-bright-1'),
        closeTo(1, .001),
        reason: 'selected lyrics reach full alpha',
      );
      expect(
        opacity('lyric-bright-0'),
        closeTo(activeBefore, .001),
        reason: 'unselected lyrics keep their original alpha',
      );
      expect(
        opacity('lyric-bright-2'),
        closeTo(inactiveBefore, .001),
        reason: 'unselected lyrics keep their original alpha',
      );
      expect(
        opacity('lyric-translation-bright-2'),
        closeTo(translationBefore, .001),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tapping the cover opens the lyric sheet; long-press offers to save it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(<Track>[_track]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        // The album backdrop flows forever; freeze it so the page settles.
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: LegacyNowPlayingPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
    final cover = find.byKey(
      const ValueKey<String>('legacy-now-playing-cover'),
    );
    final covers = find.byType(LegacyCover);
    expect(covers, findsOneWidget);

    // A tap folds the cover away for the full-height lyric sheet, and does not
    // open a large artwork or a save prompt.
    await tester.tap(cover);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(covers, findsNothing, reason: 'the lyric sheet replaced the cover');
    expect(find.byType(LyricViewport), findsOneWidget);

    // Tapping the sheet again returns to the cover.
    await tester.tapAt(const Offset(195, 60));
    await tester.pumpAndSettle();
    expect(covers, findsOneWidget);

    await tester.longPress(cover);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('保存封面'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
