import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/lyrics/lyric_quality.dart';

void main() {
  final LyricFxGovernor governor = LyricFxGovernor.instance;
  setUp(governor.debugReset);
  tearDown(governor.debugReset);

  void window(int cost) {
    for (int i = 0; i < 120; i++) {
      governor.record(cost, refreshRate: 60);
    }
  }

  test('fixed qualities ignore the governor', () {
    window(40000);
    expect(lyricFxTierFor(LyricFxQuality.high), LyricFxTier.full);
    expect(lyricFxTierFor(LyricFxQuality.low), LyricFxTier.minimal);
  });

  test('auto steps down one tier per janky window and back up slowly', () {
    expect(lyricFxTierFor(LyricFxQuality.auto), LyricFxTier.full);
    window(40000);
    expect(governor.tier, LyricFxTier.reduced);
    window(40000);
    expect(governor.tier, LyricFxTier.minimal);
    window(40000);
    expect(governor.tier, LyricFxTier.minimal);
    // A few smooth seconds are not enough to climb back.
    for (int i = 0; i < 5; i++) {
      window(4000);
    }
    expect(governor.tier, LyricFxTier.minimal);
    for (int i = 0; i < 200; i++) {
      window(4000);
    }
    expect(governor.tier, LyricFxTier.full);
  });
}
