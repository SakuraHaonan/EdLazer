import 'package:flutter/material.dart';

import '../motion/ed_motion.dart';

/// Shared-axis route transition.
///
/// The incoming route fades and travels [EdMotion.travel] along X on the
/// spring curve; the route underneath shifts the other way. A system or edge
/// back gesture stays linear so the page tracks the finger. Opacity and
/// translation only — no scale, shadow, or blur.
class EdSharedAxisPageTransitionsBuilder extends PageTransitionsBuilder {
  const EdSharedAxisPageTransitionsBuilder();

  @override
  Duration get transitionDuration => EdMotion.settleDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (EdMotion.reducedOf(context)) return child;
    // A finger-driven pop writes the route animation directly. Curving it
    // would leave the page behind the finger.
    final bool tracking = route.popGestureInProgress;
    final Animation<double> primary = tracking
        ? animation
        : CurvedAnimation(
            parent: animation,
            curve: EdMotion.curve,
            reverseCurve: EdMotion.curve,
          );
    final Animation<double> secondary = tracking
        ? secondaryAnimation
        : CurvedAnimation(
            parent: secondaryAnimation,
            curve: EdMotion.curve,
            reverseCurve: EdMotion.curve,
          );
    return SlideTransition(
      position: Tween<Offset>(
        begin: Offset.zero,
        end: const Offset(-EdMotion.travel * 0.45, 0),
      ).animate(secondary),
      child: FadeTransition(
        opacity: primary,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(EdMotion.travel, 0),
            end: Offset.zero,
          ).animate(primary),
          child: RepaintBoundary(child: child),
        ),
      ),
    );
  }
}
