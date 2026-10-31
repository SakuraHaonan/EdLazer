import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/player/now_playing_route.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The route's own vertical travel: the largest translation on screen (the
/// page content underneath only uses small or zero offsets).
double _offset(WidgetTester tester) => tester
    .widgetList<FractionalTranslation>(find.byType(FractionalTranslation))
    .map((widget) => widget.translation.dy)
    .fold<double>(0, (a, b) => b > a ? b : a);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a released pull-down dismisses from where the finger left', (
    tester,
  ) async {
    final state = AppState(catalog: Catalog());
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: key, home: const SizedBox()),
    );
    final route = NowPlayingRoute(state: state);
    key.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(route.canStart, isTrue);

    route.startPull();
    route.updatePull(.5);
    await tester.pump();
    expect(_offset(tester), closeTo(.5, .01));

    route.endPull(1500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    // The page keeps moving down from the release point instead of snapping
    // back up to the curved value of the same controller position.
    expect(_offset(tester), greaterThanOrEqualTo(.5));

    await tester.pump(const Duration(seconds: 1));
    expect(route.isActive, isFalse);
    state.dispose();
  });
}
