// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;

double _bezier(double x, double x1, double y1, double x2, double y2) {
  double axis(double t, double a, double b) =>
      3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 40; i++) {
    final t = (lo + hi) / 2;
    if (axis(t, x1, x2) < x) {
      lo = t;
    } else {
      hi = t;
    }
  }
  return axis((lo + hi) / 2, y1, y2);
}

double _emp(double x) => x < .5
    ? _bezier(x * 2, .2, .4, .58, 1)
    : 1 - _bezier((x - .5) * 2, .3, 0, .58, 1);
final List<double> _emphasisSamples = List<double>.unmodifiable([
  for (var i = 0; i <= 32; i++) _emp(i / 32),
]);
final List<double> _floatSamples = List<double>.unmodifiable([
  for (var i = 0; i <= 32; i++) math.sin(i / 32 * math.pi),
]);

double _sample32(double x, List<double> samples) {
  final frame = x.clamp(0.0, 1.0) * 32;
  final lower = frame.floor().clamp(0, 32), upper = (lower + 1).clamp(0, 32);
  return samples[lower] + (samples[upper] - samples[lower]) * (frame - lower);
}

class LyricWordMotion {
  const LyricWordMotion({
    this.scale = 1,
    this.xEm = 0,
    this.yEm = 0,
    this.glow = 0,
    this.glowRadiusEm = 0,
  });
  final double scale, xEm, yEm, glow, glowRadiusEm;
  static double maskBoundary(
    double elapsedMs,
    double durationMs,
    double textWidth,
  ) => elapsedMs / math.max(1, durationMs) * textWidth;

  static LyricWordMotion ordinary(double elapsedMs, double durationMs) =>
      LyricWordMotion(
        yEm:
            -.05 *
            _bezier(
              (elapsedMs / math.max(1000, durationMs)).clamp(0.0, 1.0),
              0,
              0,
              .58,
              1,
            ),
      );

  static LyricWordMotion emphasized(
    double elapsedMs,
    double durationMs,
    int index,
    int count, {
    bool last = false,
  }) {
    var du = math.max(1000.0, durationMs);
    var amount = du / 2000, blur = du / 3000;
    amount =
        (amount > 1 ? math.sqrt(amount) : math.pow(amount, 3).toDouble()) * .6;
    blur = (blur > 1 ? math.sqrt(blur) : math.pow(blur, 3).toDouble()) * .5;
    if (last) {
      amount *= 1.6;
      blur *= 1.5;
      du *= 1.2;
    }
    amount = math.min(1.2, amount);
    blur = math.min(.8, blur);
    final delay = du / 2.5 / math.max(1, count) * index;
    final emp = _sample32((elapsedMs - delay) / du, _emphasisSamples);
    final float = _sample32(
      (elapsedMs - delay + 400) / (du * 1.4),
      _floatSamples,
    );
    return LyricWordMotion(
      scale: 1 + emp * .1 * amount,
      xEm: -emp * .03 * amount * (count / 2 - index),
      yEm: -emp * .025 * amount - float * .05,
      glow: emp * blur,
      glowRadiusEm: math.min(.3, blur * .3),
    );
  }
}
