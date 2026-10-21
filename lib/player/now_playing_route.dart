import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'now_playing_page.dart';

/// New presentation route. It expands the player from a soft, slightly
/// recessed card into the full window instead of the old bottom-sheet route.
Future<void> openNowPlayingPage(BuildContext context, AppState state) {
  return Navigator.of(context).push<void>(NowPlayingRoute(state: state));
}

class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({required this.state});

  final AppState state;

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 380);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 280);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => NowPlayingPage(state: state);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final Animation<double> enter = CurvedAnimation(
      parent: animation,
      curve: const Cubic(.2, .82, .2, 1),
      reverseCurve: const Cubic(.4, 0, 1, .7),
    );
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: const Interval(.08, 1, curve: Curves.easeOut),
        reverseCurve: Curves.easeIn,
      ),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .035),
          end: Offset.zero,
        ).animate(enter),
        child: RepaintBoundary(child: child),
      ),
    );
  }
}
