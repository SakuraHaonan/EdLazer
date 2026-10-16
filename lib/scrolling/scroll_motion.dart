import 'dart:math' as math;

abstract final class ScrollMotion {
  static const minRetention = 0.85;
  static const maxRetention = 0.98;
  static const defaultRetention = 0.90;
  static const minAcceleration = 0.5;
  static const maxAcceleration = 3.0;
  static const defaultAcceleration = 1.0;

  // Keep the input impulse independent of friction. Otherwise increasing
  // retention reduces the initial velocity and cancels the extra distance.
  static double wheelVelocity(
    double delta, {
    double acceleration = defaultAcceleration,
  }) => delta * -math.log(0.95) * 60 * acceleration;

  /// Opposite impulses brake existing motion before accelerating in reverse.
  static double addWheelImpulse(
    double velocity,
    double delta, {
    double acceleration = defaultAcceleration,
  }) => (velocity + wheelVelocity(delta, acceleration: acceleration)).clamp(
    -12000.0,
    12000.0,
  );

  static double carriedVelocity(
    double velocity, {
    double acceleration = defaultAcceleration,
  }) => (velocity * .65 * acceleration).clamp(-8000.0, 8000.0);
}
