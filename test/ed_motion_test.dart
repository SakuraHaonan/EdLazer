import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/motion/ed_motion.dart';

void main() {
  test('the settle spring accelerates before it coasts', () {
    expect(EdMotion.travelled(0), 0);
    expect(EdMotion.travelled(EdMotion.settleSeconds), greaterThan(0.99));

    final double first = EdMotion.travelled(0.04);
    final double second = EdMotion.travelled(0.08) - first;
    expect(first, greaterThan(0));
    expect(
      second,
      greaterThan(first),
      reason: 'a release from rest speeds up; an ease-out would slow down',
    );

    expect(EdMotion.curve.transform(0), 0);
    expect(EdMotion.curve.transform(1), 1);
    expect(EdMotion.curve.transform(0.5), closeTo(EdMotion.timed(0.5), 1e-9));
  });

  test(
    'fade-through drops the outgoing surface before the incoming is opaque',
    () {
      expect(EdMotion.throughOut(0), 1);
      expect(EdMotion.throughOut(0.42), 0);
      expect(EdMotion.throughIn(0.28), 0);
      expect(EdMotion.throughIn(1), 1);
      // The overlap is the gap between incoming start and outgoing end.
      expect(EdMotion.throughIn(0.35), greaterThan(0));
      expect(EdMotion.throughOut(0.35), greaterThan(0));
      expect(EdMotion.throughOut(0.5), 0);
      expect(EdMotion.throughIn(0.5), lessThan(1));
    },
  );
}
