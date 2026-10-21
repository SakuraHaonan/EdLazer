import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/widgets/lyric_edge_fade.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]真昼の無彩色を不器用な色にして',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]正午的灰质着作蹩脚的色彩',
    ].join('\n'),
  );
}

class _LongCatalog extends Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc:
        '[00:00.00]一二三四五六七八九十一二三四五六七八九十一二三四五六\n'
        '[00:05.00]第二行歌词',
    tlyric: '[00:00.00]翻译',
  );
}

void main() {
  testWidgets(
    'lyrics use AMLL blur levels and manual browsing clears blur gradually',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await (FontLoader('MiSans')
            ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
            ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf')))
          .load();
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      const track = Track(
        id: '1',
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 2),
        coverSeed: 0,
      );
      state.playQueue([track]);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLegacyTheme(),
          home: Material(
            child: Center(
              child: RepaintBoundary(
                key: key,
                child: SizedBox(
                  width: 340,
                  height: 500,
                  child: ColoredBox(
                    color: const Color(0xFFF0EEE6),
                    child: LyricViewport(state: state),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      state.seek(30 / 120);
      await tester.pumpAndSettle();
      final viewport = find.byType(LyricViewport);
      expect(
        find.descendant(
          of: viewport,
          matching: find.byType(LyricEdgeFade),
        ),
        findsOneWidget,
      );
      final focused = find.byKey(const ValueKey('lyric-blur-15'));
      final adjacent = find.byKey(const ValueKey('lyric-blur-16'));
      expect(tester.widget<ImageFiltered>(focused).enabled, false);
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(
        tester.widget<ImageFiltered>(adjacent).imageFilter,
        equals(ui.ImageFilter.blur(sigmaX: 1.55, sigmaY: 1.55)),
        reason: 'blur follows the row\'s distance from the focus band',
      );
      if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(
            'diag/lyrics_amll_transition.png',
          ).writeAsBytes(png.buffer.asUint8List());
          image.dispose();
        });
      }
      final before = tester.widget<ImageFiltered>(adjacent).imageFilter;
      final gesture = await tester.startGesture(tester.getCenter(viewport));
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(tester.widget<ImageFiltered>(adjacent).imageFilter, isNot(before));
      await tester.pump(const Duration(milliseconds: 250));
      expect(tester.widget<ImageFiltered>(adjacent).enabled, false);
      await gesture.up();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(tester.widget<ImageFiltered>(focused).enabled, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('wrapped main lyric keeps its measured height and spacing', (
    tester,
  ) async {
    const Track track = Track(
      id: 'long',
      title: 'Long line',
      artist: 'Artist',
      album: 'Album',
      duration: Duration(minutes: 2),
      coverSeed: 0,
    );
    final state = AppState(catalog: _LongCatalog());
    addTearDown(state.dispose);
    state.playQueue(<Track>[track]);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: const Color(0xFF35237A),
                child: SizedBox(
                  width: 340,
                  height: 500,
                  child: LyricViewport(state: state),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row0 = tester.getRect(
      find.byKey(const ValueKey('lyric-line-long-0')),
    );
    final row1 = tester.getRect(
      find.byKey(const ValueKey('lyric-line-long-1')),
    );
    final main0 = tester.getRect(
      find.byKey(const ValueKey('lyric-main-0')),
    );
    final translation0 = tester.getRect(
      find.byKey(const ValueKey('lyric-translation-0')),
    );
    expect(main0.height, greaterThan(30), reason: 'the main lyric wraps');
    expect(translation0.top - main0.bottom, closeTo(5, .01));
    expect(
      translation0.bottom,
      lessThanOrEqualTo(row0.bottom + .01),
      reason: 'wrapped content must stay inside the measured row height',
    );
    expect(row1.top, greaterThanOrEqualTo(row0.bottom));
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final png = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await File(
          'diag/wrapped_lyric_spacing.png',
        ).writeAsBytes(png.buffer.asUint8List());
        image.dispose();
      });
    }
    state.pause();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
