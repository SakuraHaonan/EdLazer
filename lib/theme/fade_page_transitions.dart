import 'package:flutter/material.dart';

import 'tokens.dart';

/// EdLazer's route transition: a quick fade with a few pixels of rise.
///
/// Replaces the Cupertino full-page slide on Android (which composited two
/// full-screen layers plus a shadow for 400 ms and fought the system back
/// gesture). Only opacity and a tiny translate are animated, both
/// compositor-only.
class EdFadePageTransitionsBuilder extends PageTransitionsBuilder {
  const EdFadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => AppMotion.standard;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Animation<double> eased = CurvedAnimation(
      parent: animation,
      curve: AppMotion.fadeCurve,
      reverseCurve: AppMotion.exitCurve,
    );
    return FadeTransition(
      opacity: eased,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, AppMotion.pageSlide * 2),
          end: Offset.zero,
        ).animate(eased),
        child: child,
      ),
    );
  }
}
