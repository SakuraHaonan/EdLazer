import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/widgets/animated_track_cover.dart';

const Track _first = Track(
  id: 'cover-first',
  title: 'First',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Track _second = Track(
  id: 'cover-second',
  title: 'Second',
  artist: 'Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

Widget _host(Track track) => MaterialApp(
  home: Center(
    child: SizedBox.square(
      dimension: 240,
      child: AnimatedTrackCover(track: track, direction: 1),
    ),
  ),
);

void main() {
  testWidgets('a track change dissolves the artwork', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_first));
    await tester.pumpAndSettle();

    await tester.pumpWidget(_host(_second));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    // Fade-through keeps the outgoing plate only while it is still visible,
    // then drops it. It is not a carousel slide.
    expect(find.byKey(const ValueKey<String>('cover-first')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover-second')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AnimatedTrackCover),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey<String>('cover-first')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cover-second')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
