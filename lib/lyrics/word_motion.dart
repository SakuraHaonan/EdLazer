import 'dart:math' as math;

double _cubicAxis(double t, double a, double b) =>
    3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;

double _cubic(double x, double x1, double y1, double x2, double y2) {
  double low = 0;
  double high = 1;
  for (var i = 0; i < 40; i++) {
    final double middle = (low + high) / 2;
    if (_cubicAxis(middle, x1, x2) < x) {
      low = middle;
    } else {
      high = middle;
    }
  }
  return _cubicAxis((low + high) / 2, y1, y2);
}

double _emphasisCurve(double x) => x < .5
    ? _cubic(x * 2, .2, .4, .58, 1)
    : 1 - _cubic((x - .5) * 2, .3, 0, .58, 1);

final List<double> _emphasisTable = List<double>.unmodifiable(<double>[
  for (var i = 0; i <= 32; i++) _emphasisCurve(i / 32),
]);
final List<double> _floatTable = List<double>.unmodifiable(<double>[
  for (var i = 0; i <= 32; i++) math.sin(i / 32 * math.pi),
]);

double _sample(double x, List<double> table) {
  final double frame = x.clamp(0.0, 1.0) * 32;
  final int low = frame.floor().clamp(0, 32);
  final int high = (low + 1).clamp(0, 32);
  return table[low] + (table[high] - table[low]) * (frame - low);
}

/// Per-word emphasis transform used by the lyric painter.
class LyricWordMotion {
  const LyricWordMotion({
    this.scale = 1,
    this.xEm = 0,
    this.yEm = 0,
    this.glow = 0,
    this.glowRadiusEm = 0,
  });

  final double scale;
  final double xEm;
  final double yEm;
  final double glow;
  final double glowRadiusEm;

  static double maskBoundary(
    double elapsedMs,
    double durationMs,
    double textWidth,
  ) => elapsedMs / math.max(1, durationMs) * textWidth;

  static LyricWordMotion ordinary(double elapsedMs, double durationMs) {
    final double progress =
        (elapsedMs / math.max(1000, durationMs)).clamp(0.0, 1.0);
    return LyricWordMotion(
      yEm: -.05 * _cubic(progress, 0, 0, .58, 1),
    );
  }

  static LyricWordMotion emphasized(
    double elapsedMs,
    double durationMs,
    int index,
    int count, {
    bool last = false,
  }) {
    double duration = math.max(1000, durationMs);
    double amount = duration / 2000;
    double blur = duration / 3000;
    amount =
        (amount > 1 ? math.sqrt(amount) : math.pow(amount, 3).toDouble()) * .6;
    blur = (blur > 1 ? math.sqrt(blur) : math.pow(blur, 3).toDouble()) * .5;
    if (last) {
      amount *= 1.6;
      blur *= 1.5;
      duration *= 1.2;
    }
    amount = math.min(1.2, amount);
    blur = math.min(.8, blur);
    final double delay = duration / 2.5 / math.max(1, count) * index;
    final double emphasis = _sample(
      (elapsedMs - delay) / duration,
      _emphasisTable,
    );
    final double float = _sample(
      (elapsedMs - delay + 400) / (duration * 1.4),
      _floatTable,
    );
    return LyricWordMotion(
      scale: 1 + emphasis * .1 * amount,
      xEm: -emphasis * .03 * amount * (count / 2 - index),
      yEm: -emphasis * .025 * amount - float * .05,
      glow: emphasis * blur,
      glowRadiusEm: math.min(.3, blur * .3),
    );
  }
}
