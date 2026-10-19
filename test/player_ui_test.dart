import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/theme/paper_widgets.dart';

void main() {
  testWidgets(
    'guest shell shows no sample tracks and settings remain concise',
    (tester) async {
      final state = AppState(catalog: Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: PlayerPage(state: state),
        ),
      );
      expect(state.queue, isEmpty);
      expect(find.text('发现音乐'), findsOneWidget);
      await tester.tap(find.text('设置').first);
      await tester.pumpAndSettle();
      expect(find.text('刷新曲库'), findsOneWidget);
      expect(find.text('循环模式'), findsNothing);
      expect(find.text('设计'), findsNothing);
    },
  );

  testWidgets('primary button fills its hit area', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: ClayButton(label: '播放', onPressed: null, expand: true),
          ),
        ),
      ),
    );
    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(tester.getSize(find.byType(TextButton)).width, 240);
    expect(
      tester.getSize(find.byType(TextButton)).height,
      greaterThanOrEqualTo(48),
    );
    expect(button.style?.backgroundColor?.resolve(<WidgetState>{}), isNotNull);
  });
}
