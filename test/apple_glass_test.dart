import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/apple_ui.dart';

void main() {
  testWidgets('every glass panel clips its own backdrop filter', (
    tester,
  ) async {
    // A BackdropFilter with nothing clipping it filters the whole screen: the
    // player bar's square glass would blur every page painted underneath it.
    // The clip is part of the effect, not decoration, so it must survive for
    // square panels too.
    for (final BorderRadius radius in <BorderRadius>[
      BorderRadius.zero,
      BorderRadius.circular(18),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: AppleGlass(
              borderRadius: radius,
              child: const SizedBox(width: 120, height: 40),
            ),
          ),
        ),
      );
      final Finder clip = find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(ClipRRect),
      );
      expect(clip, findsOneWidget, reason: 'unclipped glass blurs the window');
      expect(tester.widget<ClipRRect>(clip).borderRadius, radius);
    }
    expect(tester.takeException(), isNull);
  });
}
