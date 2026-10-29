import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoFullscreenDialogTransition;

import '../motion/ed_motion.dart';

/// A vertical page transition with a platform-independent top-edge back drag.
/// The route animation exposes the actual previous page during the gesture.
class PullDownPageRoute<T> extends MaterialPageRoute<T> {
  PullDownPageRoute({required super.builder, super.settings});

  NavigatorState? _pullNavigator;
  bool _settling = false;
  bool _disposed = false;
  bool get _pulling => _pullNavigator != null;

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;
  @override
  Duration get transitionDuration => EdMotion.settleDuration;
  @override
  Duration get reverseTransitionDuration => EdMotion.settleDuration;

  bool get _canStartPull =>
      !_disposed &&
      !_pulling &&
      !_settling &&
      popGestureEnabled &&
      !(navigator?.userGestureInProgress ?? true);

  bool _startPull() {
    if (!_canStartPull) return false;
    _pullNavigator = navigator;
    _pullNavigator!.didStartUserGesture();
    return true;
  }

  void _updatePull(double progress) {
    if (_pulling && !_settling && isCurrent) {
      // Keep the route alive even when the finger reaches the bottom edge.
      controller!.value = (1 - progress).clamp(.001, 1);
    }
  }

  Future<void> _settlePull({
    bool cancel = false,
    bool alreadyPopped = false,
    double velocity = 0,
    bool reduceMotion = false,
  }) async {
    if (!_pulling || _settling || _disposed) return;
    _settling = true;
    final nav = _pullNavigator!;
    final progress = 1 - controller!.value;
    final wantsPop = velocity < -700
        ? false
        : velocity > 700 && progress > .025 || progress >= .28;
    final commit =
        alreadyPopped ||
        (!cancel &&
            wantsPop &&
            isCurrent &&
            !willHandlePopInternally &&
            popDisposition == RoutePopDisposition.pop);
    final leaving = commit || !isActive;
    try {
      if (commit && !alreadyPopped) {
        nav.pop();
        // Replace TransitionRoute's pop simulation before the next frame so
        // the page continues from the exact position where the finger left.
        controller!.stop(canceled: false);
      }
      final double height = nav.context.mounted
          ? MediaQuery.sizeOf(nav.context).height
          : 0;
      // Finger velocity is pixels per second, downward-positive. The route
      // controller falls as the page is pulled down.
      final double unitsPerSecond = height <= 0 ? 0.0 : -velocity / height;
      await EdMotion.springTo(
        controller!,
        leaving ? 0 : 1,
        velocity: unitsPerSecond,
        reduced: reduceMotion,
      ).orCancel;
    } on TickerCanceled {
      // Removing the route or disposing its navigator cancels the settlement.
    } finally {
      _settling = false;
      _releasePull();
    }
  }

  void _releasePull({bool defer = false}) {
    final nav = _pullNavigator;
    _pullNavigator = null;
    if (nav == null) return;
    void release() {
      if (nav.mounted && nav.userGestureInProgress) nav.didStopUserGesture();
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => release());
    } else {
      release();
    }
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    if (popped && _pulling && !_settling) {
      unawaited(_settlePull(alreadyPopped: true));
    }
    return popped;
  }

  @override
  void dispose() {
    _disposed = true;
    _releasePull(defer: true);
    super.dispose();
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final platform = Theme.of(context).platform;
    final isMobilePlatform =
        platform == TargetPlatform.iOS || platform == TargetPlatform.android;
    final page = AnimatedBuilder(
      animation: Listenable.merge([
        animation,
        navigator!.userGestureInProgressNotifier,
      ]),
      child: child,
      builder: (context, child) {
        final systemBack = popGestureInProgress && !_pulling;
        if (systemBack && platform == TargetPlatform.iOS) {
          return CupertinoFullscreenDialogTransition(
            primaryRouteAnimation: animation,
            secondaryRouteAnimation: secondaryAnimation,
            linearTransition: true,
            child: child!,
          );
        }
        final progress = _pulling || _settling
            ? animation.value
            : EdMotion.curve.transform(animation.value);
        return SlideTransition(
          key: const ValueKey('now-playing-page-transition'),
          position: AlwaysStoppedAnimation(
            Offset(0, systemBack ? 0 : 1 - progress),
          ),
          child: child,
        );
      },
    );
    final interactive = LayoutBuilder(
      builder: (context, box) => _TopEdgeBackGesture(
        enabled: isMobilePlatform || box.maxWidth < 720,
        activationHeight: MediaQuery.paddingOf(context).top + 64,
        height: box.maxHeight,
        canStart: () => _canStartPull,
        onStart: _startPull,
        onUpdate: _updatePull,
        onEnd: (velocity, cancel) => unawaited(
          _settlePull(
            velocity: velocity,
            cancel: cancel,
            reduceMotion: MediaQuery.disableAnimationsOf(context),
          ),
        ),
        child: page,
      ),
    );
    if (platform != TargetPlatform.android) return interactive;
    // Android's system edge back remains available alongside the app gesture.
    return const PredictiveBackFullscreenPageTransitionsBuilder()
        .buildTransitions(
          this,
          context,
          popGestureInProgress && !_pulling
              ? animation
              : const AlwaysStoppedAnimation(1),
          secondaryAnimation,
          interactive,
        );
  }
}

class _TopEdgeBackGesture extends StatefulWidget {
  const _TopEdgeBackGesture({
    required this.enabled,
    required this.activationHeight,
    required this.height,
    required this.canStart,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
  });
  final bool enabled;
  final double activationHeight, height;
  final bool Function() canStart, onStart;
  final ValueChanged<double> onUpdate;
  final void Function(double velocity, bool cancel) onEnd;
  final Widget child;
  @override
  State<_TopEdgeBackGesture> createState() => _TopEdgeBackGestureState();
}

class _TopEdgeBackGestureState extends State<_TopEdgeBackGesture> {
  bool _started = false;
  double _origin = 0, _distance = 0, _height = 1;

  void _start(DragStartDetails details) {
    if (!widget.onStart()) return;
    _started = true;
    _height = widget.height;
    _distance = details.localPosition.dy - _origin;
    widget.onUpdate(_distance / _height);
  }

  void _update(DragUpdateDetails details) {
    if (!_started) return;
    _distance = (_distance + details.delta.dy).clamp(0, _height);
    widget.onUpdate(_distance / _height);
  }

  void _end(double velocity, {bool cancel = false}) {
    if (!_started) return;
    _started = false;
    widget.onEnd(velocity, cancel);
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.translucent,
    excludeFromSemantics: true,
    gestures: {
      _TopEdgeDragRecognizer:
          GestureRecognizerFactoryWithHandlers<_TopEdgeDragRecognizer>(
            () => _TopEdgeDragRecognizer(debugOwner: this),
            (recognizer) {
              recognizer.canStart = () =>
                  widget.enabled && widget.height > 0 && widget.canStart();
              recognizer.activationHeight = widget.activationHeight;
              recognizer.onDown = (details) {
                _origin = details.localPosition.dy;
              };
              recognizer.onStart = _start;
              recognizer.onUpdate = _update;
              recognizer.onEnd = (details) =>
                  _end(details.velocity.pixelsPerSecond.dy);
              recognizer.onCancel = () => _end(0, cancel: true);
            },
          ),
    },
    child: widget.child,
  );
}

class _TopEdgeDragRecognizer extends VerticalDragGestureRecognizer {
  _TopEdgeDragRecognizer({super.debugOwner});
  double activationHeight = 0;
  bool Function()? canStart;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) => globalDistanceMoved > computeHitSlop(pointerDeviceKind, gestureSettings);

  @override
  bool isPointerAllowed(PointerEvent event) {
    return event is PointerDownEvent &&
        event.localPosition.dy >= 0 &&
        event.localPosition.dy <= activationHeight &&
        (canStart?.call() ?? false) &&
        super.isPointerAllowed(event);
  }
}
