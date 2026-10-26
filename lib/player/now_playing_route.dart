import 'package:flutter/material.dart';

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

  /// Time the pull takes to cover its whole travel when it settles.
  static const Duration _settleDuration = Duration(milliseconds: 260);

  /// A pull may only begin once the route has finished presenting itself.
  @override
  bool get canStart =>
      isCurrent && animation?.status == AnimationStatus.completed;

  @override
  void startPull() => controller?.stop();

  @override
  void updatePull(double progress) {
    // Stay off the lower bound: popping, not dragging, finishes the dismissal.
    controller?.value = (1 - progress).clamp(.001, 1);
  }

  @override
  void endPull(double velocity) {
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
    controller?.animateTo(
      1,
      duration: Duration(
        milliseconds: (pulled * _settleDuration.inMilliseconds).round().clamp(
          80,
          260,
        ),
      ),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  bool get opaque => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

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
    // Linear on purpose: the pull drives this same animation, so a curve here
    // would leave the page trailing the finger.
    return SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(animation),
      child: RepaintBoundary(child: child),
    );
  }
}
