import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/lyric_edge_fade.dart';

void main() {
  testWidgets('lyric edge fade dissolves all four raster edges', (
    tester,
  ) async {
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
      int alpha(int x, int y) => bytes.getUint8((y * image.width + x) * 4 + 3);
      for (final int Function(int) sample in <int Function(int)>[
        (n) => alpha(n, 160),
        (n) => alpha(239 - n, 160),
        (n) => alpha(120, n),
        (n) => alpha(120, 319 - n),
      ]) {
        expect(sample(0), lessThanOrEqualTo(4));
        expect(sample(4), greaterThan(sample(0)));
        expect(sample(8), greaterThan(sample(4)));
        expect(sample(12), greaterThan(sample(8)));
      }
      expect(alpha(120, 160), 255);
      image.dispose();
    });
  });

  testWidgets('a wide canvas can keep only the vertical mask pass', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: LyricEdgeFade(
          verticalExtent: 40,
          horizontal: false,
          child: SizedBox.expand(),
        ),
      ),
    );
    final Finder fade = find.byType(LyricEdgeFade);
    expect(
      find.descendant(of: fade, matching: find.byType(ShaderMask)),
      findsOneWidget,
      reason: 'the gutter already contains the horizontal blur halo',
    );
  });
}
