import 'dart:math' as math;

/// Spring constants for one lyric row.
class LyricSpringParams {
  const LyricSpringParams({
    this.mass = 1,
    this.damping = 10,
    this.stiffness = 100,
    this.soft = false,
  });

  final double mass;
  final double damping;
  final double stiffness;
  final bool soft;
}

/// Closed-form damped spring with velocity-preserving retargeting.
///
/// The solver is deterministic to the same frame samples as the reference
/// implementation, but is a fresh rewrite of the state machine around it.
class LyricSpring {
  LyricSpring(double position, {LyricSpringParams? params})
    : value = position,
      target = position,
      _params = params ?? const LyricSpringParams() {
    _solution = (_) => target;
    _settled = true;
  }

  double value;
  double target;

  double _elapsed = 0;
  LyricSpringParams _params;
  late double Function(double) _solution;
  (double delay, double target)? _pending;
  bool _settled = false;

  bool get arrived => _settled;

  void setParameters(LyricSpringParams params) {
    _pending = null;
    _params = params;
    _restart();
  }

  void setPosition(double position) {
    value = position;
    target = position;
    _pending = null;
    _solution = (_) => target;
    _settled = true;
  }

  void setTarget(double position, {double delay = 0}) {
    if (delay <= 0 && (target - position).abs() < 0.001) {
      _pending = null;
      return;
    }
    if (delay > 0) {
      _pending = (delay, position);
      _settled = false;
    } else {
      _pending = null;
      target = position;
      _restart();
    }
  }

  void update(double seconds) {
    _elapsed += seconds;
    value = _solution(_elapsed);
    final (double delay, double nextTarget)? pending = _pending;
    if (pending != null) {
      final double remaining = pending.$1 - seconds;
      _pending = (remaining, pending.$2);
      if (remaining <= 0) setTarget(pending.$2);
    }
    final double velocity = _velocity(_elapsed);
    final double acceleration = _acceleration(_elapsed);
    _settled =
        (target - value).abs() < 0.01 &&
        velocity.abs() < 0.01 &&
        acceleration.abs() < 0.01 &&
        _pending == null;
    if (_settled) setPosition(target);
  }

  double _velocity(double at) =>
      (_solution(at + 0.001) - _solution(at - 0.001)) / 0.002;

  double _acceleration(double at) =>
      (_velocity(at + 0.001) - _velocity(at - 0.001)) / 0.002;

  void _restart() {
    final double velocity = _velocity(_elapsed);
    _elapsed = 0;
    _solution = solveLyricSpring(value, velocity, target, _params);
    _settled = false;
  }
}

/// Closed-form solution for a damped harmonic oscillator.
double Function(double) solveLyricSpring(
  double from,
  double velocity,
  double to,
  LyricSpringParams params,
) {
  final double delta = to - from;
  final double stiffness = params.stiffness;
  final double damping = params.damping;
  final double mass = params.mass;
  final double critical = 2 * math.sqrt(stiffness * mass);
  if (params.soft || damping / critical >= 1) {
    final double frequency = -math.sqrt(stiffness / mass);
    final double leftover = -frequency * delta - velocity;
    return (double t) =>
        to - (delta + t * leftover) * math.exp(t * frequency);
  }
  final double frequency = math.sqrt(4 * mass * stiffness - damping * damping);
  final double leftover = (damping * delta - 2 * mass * velocity) / frequency;
  final double cosineRate = .5 * frequency / mass;
  final double decay = -.5 * damping / mass;
  return (double t) =>
      to -
      (math.cos(t * cosineRate) * delta +
              math.sin(t * cosineRate) * leftover) *
          math.exp(t * decay);
}

/// Adaptive position spring: long gaps get a softer arrival, seeks and
/// interludes use the standard mass/damping pair.
LyricSpringParams lyricPositionPolicy({
  bool seeking = false,
  bool interlude = false,
  int? intervalMs,
  bool endOfSong = false,
}) {
  if (seeking || interlude || (!endOfSong && intervalMs == null)) {
    return const LyricSpringParams(mass: .9, stiffness: 90, damping: 15);
  }
  if (endOfSong) {
    return const LyricSpringParams(mass: .9, stiffness: 140, damping: 22);
  }
  final int interval = intervalMs!.clamp(100, 800);
  final double ratio = math.pow(1 - (interval - 100) / 700, .2).toDouble();
  final double stiffness = 170 + ratio * 50;
  return LyricSpringParams(
    mass: .9,
    stiffness: stiffness,
    damping: math.sqrt(stiffness) * 2.2,
  );
}

/// Stagger is measured after the active row and decays by 1/1.05.
List<double> lyricStaggerDelays(
  List<double> positions,
  List<double> heights,
  int active, {
  bool disabled = false,
}) {
  double offset = 0;
  double step = disabled ? 0 : .05;
  return List<double>.generate(positions.length, (int index) {
    final double result = offset;
    if (positions[index] + heights[index] >= 0) {
      offset += step;
      if (index >= active) step /= 1.05;
    }
    return result;
  });
}
