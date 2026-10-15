import 'dart:math' as math;

abstract final class ScrollMotion {
  static const minRetention = 0.85;
  static const maxRetention = 0.98;
  static const defaultRetention = 0.90;

  // Keep the input impulse independent of friction. Otherwise increasing
  // retention reduces the initial velocity and cancels the extra distance.
  static double wheelVelocity(double delta) => delta * -math.log(0.95) * 60;
}
