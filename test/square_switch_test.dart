import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/square_switch_list_tile.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'square settings toggle supports mouse, keyboard, accessibility and saved state',
    (tester) async {
      final state = AppState();
      addTearDown(state.dispose);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            home: Scaffold(
              body: SquareSwitchListTile(
                title: const Text('震动反馈'),
                subtitle: const Text('操作反馈'),
                value: state.hapticsEnabled,
                onChanged: state.setHapticsEnabled,
              ),
            ),
          ),
        ),
      );
      final toggle = find.byType(SquareSwitchListTile);
      var semantics = tester.getSemantics(toggle).getSemanticsData();
      expect(semantics.flagsCollection.isToggled, ui.Tristate.isTrue);
      await tester.tap(find.text('操作反馈'));
      await tester.pumpAndSettle();
      expect(state.hapticsEnabled, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(state.hapticsEnabled, true);
      final node = tester.getSemantics(toggle);
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(state.hapticsEnabled, false);
      semantics = tester.getSemantics(toggle).getSemanticsData();
      expect(semantics.flagsCollection.isToggled, ui.Tristate.isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool('lazer_haptics'),
        false,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
