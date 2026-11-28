import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import 'package:lazer_nextgen/widgets/apple_ui.dart';

void main() {
  testWidgets('glass panels use the liquid-glass material', (tester) async {
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
      expect(find.byType(LiquidGlass), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}
