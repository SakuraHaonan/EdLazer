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

void main() {
  testWidgets(
    'blurred pixels fade continuously to transparency at all four edges',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 240,
                height: 320,
                child: LyricEdgeFade(
                  verticalExtent: 64,
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                    child: const ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        int alpha(int x, int y) =>
            bytes.getUint8((y * image.width + x) * 4 + 3);
        for (final sample in <int Function(int)>[
          (n) => alpha(n, 160),
          (n) => alpha(239 - n, 160),
          (n) => alpha(120, n),
          (n) => alpha(120, 319 - n),
        ]) {
          expect(
            sample(0),
            lessThanOrEqualTo(4),
            reason: 'no visible hard edge',
          );
          expect(sample(4), greaterThan(sample(0)));
          expect(sample(8), greaterThan(sample(4)));
          expect(sample(12), greaterThan(sample(8)));
        }
        expect(
          alpha(120, 160),
          255,
          reason: 'the focus band keeps full opacity',
        );
        image.dispose();
      });
    },
  );

  testWidgets(
    'lyric viewport fades after blur and manual browsing clears blur gradually',
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
      final fade = find.descendant(
        of: viewport,
        matching: find.byType(LyricEdgeFade),
      );
      expect(fade, findsOneWidget);
      final focused = find.byKey(const ValueKey('lyric-blur-15'));
      final adjacent = find.byKey(const ValueKey('lyric-blur-16'));
      expect(tester.widget<ImageFiltered>(focused).enabled, false);
      expect(tester.widget<ImageFiltered>(adjacent).enabled, true);
      expect(find.descendant(of: fade, matching: adjacent), findsOneWidget);
      if (const bool.fromEnvironment('SAVE_UI_PROBES')) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage();
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          await File(
            'diag/lyrics_soft_edges.png',
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
}
