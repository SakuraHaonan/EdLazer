import 'package:flutter/material.dart';

import '../motion/ed_motion.dart';
import '../navigation/pull_down_to_close.dart';
import '../state/app_state.dart';
import 'now_playing_page.dart';

/// Material open-upwards presentation: the player rises from the window
/// bottom to the top and reverses on close.
Future<void> openNowPlayingPage(BuildContext context, AppState state) {
  return Navigator.of(context).push<void>(NowPlayingRoute(state: state));
}

/// The player as a route.
///
/// The route doubles as the host of the player's pull-down dismissal: it hands
/// the drag its own transition animation, so a finger drag and the close
/// transition are one continuous motion.
class NowPlayingRoute extends PageRoute<void> implements PlayerPullDown {
  NowPlayingRoute({required this.state});

  final AppState state;

  /// Whether a finger owns the transition right now.
  ///
  /// The drag writes [controller] directly, so the offset has to stay linear
  /// with the finger. The spring that finishes a released pull writes the
  /// controller too ([_settling]); only a navigator push or pop is sampled
  /// through [EdMotion.curve].
  bool _dragging = false;
  bool _settling = false;

  /// A pull may only begin once the route has finished presenting itself.
  @override
  bool get canStart =>
      isCurrent && animation?.status == AnimationStatus.completed;

  @override
  void startPull() {
    _dragging = true;
    controller?.stop();
  }

  @override
  void updatePull(double progress) {
    // Stay off the lower bound: popping, not dragging, finishes the dismissal.
    controller?.value = (1 - progress).clamp(.001, 1);
  }

  @override
  void endPull(double velocity) {
    _dragging = false;
    final double open = controller?.value ?? 1;
    final double pulled = 1 - open;
    final bool dismiss = velocity < -900
        ? false
        : (velocity > 900 && pulled > .02) || pulled >= .22;
    if (dismiss) {
      // Popping continues the route's own reverse transition from here.
      navigator?.pop();
      return;
    }
    final AnimationController? host = controller;
    if (host == null) return;
    _settling = true;
    final NavigatorState? nav = navigator;
    final bool navReady = nav != null && nav.mounted;
    final double height = navReady ? MediaQuery.sizeOf(nav.context).height : 0;
    final double unitsPerSecond = height <= 0 ? 0 : -velocity / height;
    final bool reduced = navReady && EdMotion.reducedOf(nav.context);
    EdMotion.springTo(
      host,
      1,
      velocity: unitsPerSecond,
      reduced: reduced,
    ).whenCompleteOrCancel(() => _settling = false);
  }

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => EdMotion.settleDuration;

  @override
  Duration get reverseTransitionDuration => EdMotion.settleDuration;

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
  ) => NowPlayingPage(state: state, pullDown: this);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    // A finger-driven pull, and the spring that finishes it, stay linear:
    // both write the controller value themselves. A navigator push or pop is
    // a timed controller, so it samples the shared spring curve.
    return AnimatedBuilder(
      animation: animation,
      child: RepaintBoundary(child: child),
      builder: (BuildContext context, Widget? child) {
        final double travelled = _dragging || _settling
            ? animation.value
            : EdMotion.curve.transform(animation.value);
        return FractionalTranslation(
          translation: Offset(0, 1 - travelled),
          child: child,
        );
      },
    );
  }
}
