import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// Chrome motion: one critically damped spring, shared by every transition
/// that is not the lyric view.
///
/// The previous system was a family of ease-out cubics (100–250 ms) with a
/// simultaneous cross-fade. This one is a single spring. A tap releases the
/// spring from rest, so it accelerates and then settles; a finger hands the
/// same spring its release velocity, so a drag and the animation that finishes
/// it are one motion and can be interrupted. Pages that have a spatial
/// relationship travel a short shared axis. Tab changes fade through, so two
/// full-screen trees are not blended for the whole transition.
///
/// Only opacity and translation are animated. Both are compositor layers on
/// top of a [RepaintBoundary]; nothing here blurs, scales a backdrop, or
/// allocates a save layer per frame.
abstract final class EdMotion {
  /// Mass, stiffness and damping of the one spring. Damping is exactly
  /// critical (`2 * sqrt(k * m)`), so a full-screen sheet never crosses the
  /// bezel and comes back.
  static const double mass = 1;
  static const double stiffness = 480;

  /// `2 * sqrt(480)`.
  static const double damping = 43.817804600206645;

  static const SpringDescription spring = SpringDescription(
    mass: mass,
    stiffness: stiffness,
    damping: damping,
  );

  /// `sqrt(stiffness / mass)`. The natural frequency of [spring].
  static const double omega = 21.908902300103322;

  /// Time at which a release from rest is within half a percent of its rest
  /// position. Routes that can only take a [Duration] sample [spring] across
  /// this window.
  static const double settleSeconds = 0.36;
  static const Duration settleDuration = Duration(milliseconds: 360);

  /// Fade-through (tabs, covers, dialogs) is a little shorter than a sheet:
  /// the outgoing surface is gone before the incoming one is fully opaque.
  static const Duration throughDuration = Duration(milliseconds: 280);

  /// Press, hover, and other micro-motions. Same curve, less time.
  static const Duration pressDuration = Duration(milliseconds: 160);

  /// In-place content arriving inside a page that is already on screen
  /// (a comment list filling in, a notice). Not a per-row stagger.
  static const Duration entranceDuration = Duration(milliseconds: 240);

  /// Shared-axis travel as a fraction of the child. Short on purpose: a
  /// full-width slide keeps two pages on the GPU for the whole gesture.
  static const double travel = 0.06;
  static const double travelLarge = 0.03;

  /// Normalized spring curve. [transform] of 0 is rest-at-the-start and
  /// [transform] of 1 is settled; the shape is [travelled], not a cubic.
  static const Curve curve = _SpringCurve();

  /// Progress of a spring released from rest, in 0..1, at [seconds].
  ///
  /// `x(t) = 1 - (1 + ω t) e^{-ω t}`.
  static double travelled(double seconds) {
    if (seconds <= 0) return 0;
    final double wt = omega * seconds;
    final double remaining = (1 + wt) * math.exp(-wt);
    final double value = 1 - remaining;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// [travelled] stretched over [settleSeconds] so a timed controller can
  /// play the same shape.
  static double timed(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    final double end = travelled(settleSeconds);
    if (end <= 0) return 1;
    final double value = travelled(t * settleSeconds) / end;
    return value < 0 ? 0 : (value > 1 ? 1 : value);
  }

  /// Fade-through opacities. The outgoing surface reaches 0 while the
  /// incoming one is still arriving, so the two layers overlap briefly
  /// instead of cross-fading the whole time.
  static double throughIn(double t) => ((t - 0.28) / 0.72).clamp(0.0, 1.0);
  static double throughOut(double t) => (1 - t / 0.42).clamp(0.0, 1.0);

  /// Shared-axis opacities. Incoming is opaque well before the spring rests,
  /// which drops the second layer early.
  static double axisIn(double t) => (t / 0.62).clamp(0.0, 1.0);
  static double axisOut(double t) => (1 - t / 0.50).clamp(0.0, 1.0);

  /// True when the platform asks for no motion, including an animator scale
  /// of zero (that is what [MediaQuery.disableAnimationsOf] reports).
  static bool reducedOf(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration durationOf(BuildContext context, Duration full) =>
      reducedOf(context) ? Duration.zero : full;

  /// Runs [spring] from the controller's current value to [target].
  ///
  /// [velocity] is in controller units per second (a fraction of the sheet,
  /// not pixels). Reduced motion jumps, so a released pull still lands.
  static TickerFuture springTo(
    AnimationController controller,
    double target, {
    double velocity = 0,
    bool reduced = false,
  }) {
    if (reduced) {
      controller.value = target.clamp(
        controller.lowerBound,
        controller.upperBound,
      );
      return TickerFuture.complete();
    }
    // Velocity tolerance is looser than the framework default (0.001) so a
    // critically damped tail counts as rested once the sheet is within a
    // pixel and barely moving. The default waits until the velocity is
    // visually zero, which is past the point the eye has stopped.
    final Simulation simulation = SpringSimulation(
      spring,
      controller.value,
      target,
      velocity,
      snapToEnd: true,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.02),
    );
    // animateWith always reports [AnimationStatus.forward], so a spring that
    // runs toward the lower bound uses animateBackWith and ends dismissed.
    if (target < controller.value) {
      return controller.animateBackWith(simulation);
    }
    return controller.animateWith(simulation);
  }
}

class _SpringCurve extends Curve {
  const _SpringCurve();

  @override
  double transformInternal(double t) => EdMotion.timed(t);
}

/// Which spatial pattern a shell navigation uses.
enum EdPattern {
  /// Bottom navigation and other siblings: fade through, with a hint of axis.
  through,

  /// Drill-in and back: the incoming page travels on the shared axis.
  axis,
}
