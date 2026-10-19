import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/scroll_inertia_setting.dart';

class _SlowCatalog extends Catalog {
  final request = Completer<HomeFeed?>();
  @override
  Future<HomeFeed?> loadHome({int? userId}) => request.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved inertia applies before the catalogue finishes loading', () async {
    SharedPreferences.setMockInitialValues({'lazer_scroll_retention': .97});
    final catalog = _SlowCatalog();
    final state = AppState(catalog: catalog);
    addTearDown(state.dispose);
    final notified = <double>[];
    state.addListener(() => notified.add(state.scrollRetention));
    final bootstrap = state.bootstrap();
    await Future<void>.delayed(Duration.zero);
    final beforeCatalogue = List<double>.of(notified);
    catalog.request.complete(null);
    await bootstrap;
    expect(beforeCatalogue, contains(.97));
  });

  testWidgets(
    'inertia can be typed, saved, clamped and reset on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState();
      addTearDown(state.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            scrollBehavior: AppScrollBehavior(retention: state.scrollRetention),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    ScrollInertiaSetting(state: state),
                    Expanded(
                      child: ListView.builder(
                        controller: scroll,
                        itemCount: 50,
                        itemBuilder: (_, i) => Text('$i'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final input = find.byKey(const ValueKey('scroll-inertia-input'));
      expect(tester.widget<TextField>(input).controller!.text, '90');
      await tester.enterText(input, '97');
      await tester.pumpAndSettle();
      expect(state.scrollRetention, .97);
      expect((scroll.position.physics as InertiaScrollPhysics).retention, .97);
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'lazer_scroll_retention',
        ),
        .97,
      );
      expect(
        tester.widget<AccessibleSlider>(find.byType(AccessibleSlider)).value,
        .97,
      );

      await tester.enterText(input, '100');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(state.scrollRetention, .98);
      expect(tester.widget<TextField>(input).controller!.text, '98');

      await tester.tap(find.byKey(const ValueKey('scroll-inertia-reset')));
      await tester.pumpAndSettle();
      expect(state.scrollRetention, .90);
      expect(tester.widget<TextField>(input).controller!.text, '90');
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'lazer_scroll_retention',
        ),
        .90,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'higher inertia increases actual wheel travel with the same input',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final content = Scaffold(
        body: ListView.builder(
          controller: scroll,
          itemExtent: 60,
          itemCount: 100,
          itemBuilder: (_, i) => Text('$i'),
        ),
      );
      Future<double> travel(double retention) async {
        await tester.pumpWidget(
          MaterialApp(
            scrollBehavior: AppScrollBehavior(retention: retention),
            home: content,
          ),
        );
        await tester.pumpAndSettle();
        scroll.jumpTo(0);
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: tester.getCenter(find.byType(ListView)),
            scrollDelta: const Offset(0, 120),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final distance = scroll.offset;
        await tester.pumpAndSettle();
        return distance;
      }

      final low = await travel(.85);
      final high = await travel(.98);
      expect(low, greaterThan(0));
      expect(high, greaterThan(low * 2));
    },
  );
}
