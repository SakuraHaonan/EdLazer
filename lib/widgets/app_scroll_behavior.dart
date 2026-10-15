import 'dart:math' as math;
import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import '../scrolling/scroll_motion.dart';

/// One retention value controls both touch flings and mouse-wheel momentum.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior({this.retention = ScrollMotion.defaultRetention});
  final double retention;
  @override
  bool shouldNotify(covariant AppScrollBehavior oldDelegate) =>
      oldDelegate.retention != retention;
  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => _WheelMomentum(details: details, retention: retention, child: child);
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      InertiaScrollPhysics(retention: retention);
}

class InertiaScrollPhysics extends ClampingScrollPhysics {
  const InertiaScrollPhysics({required this.retention, super.parent});
  final double retention;
  @override
  InertiaScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      InertiaScrollPhysics(retention: retention, parent: buildParent(ancestor));
  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    if (position.outOfRange) {
      return super.createBallisticSimulation(position, velocity);
    }
    if (velocity.abs() < tolerance.velocity ||
        (velocity < 0 && position.pixels <= position.minScrollExtent) ||
        (velocity > 0 && position.pixels >= position.maxScrollExtent)) {
      return null;
    }
    return FrictionSimulation(
      math.pow(retention, 60).toDouble(),
      position.pixels,
      velocity,
      tolerance: tolerance,
    );
  }
}

class _WheelMomentum extends StatefulWidget {
  const _WheelMomentum({
    required this.details,
    required this.retention,
    required this.child,
  });
  final ScrollableDetails details;
  final double retention;
  final Widget child;
  @override
  State<_WheelMomentum> createState() => _WheelMomentumState();
}

class _WheelMomentumState extends State<_WheelMomentum>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  double _velocity = 0;
  Duration _last = Duration.zero;

  ScrollPosition? get _position {
    final controller = widget.details.controller;
    return controller != null && controller.positions.length == 1
        ? controller.position
        : null;
  }

  void _stop() {
    _ticker.stop();
    _velocity = 0;
    _last = Duration.zero;
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final position = _position;
    if (position == null || _velocity.abs() < 5) {
      _stop();
      return;
    }
    if (dt <= 0 || dt > 0.1) return;
    final next = (position.pixels + _velocity * dt).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next == position.pixels) {
      _stop();
      return;
    }
    position.jumpTo(next);
    _velocity *= math.pow(widget.retention, dt * 60);
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final position = _position;
    if (position == null ||
        !position.physics.shouldAcceptUserOffset(position)) {
      return;
    }
    final horizontal =
        axisDirectionToAxis(widget.details.direction) == Axis.horizontal;
    var delta = horizontal ? event.scrollDelta.dx : event.scrollDelta.dy;
    if (widget.details.direction == AxisDirection.up ||
        widget.details.direction == AxisDirection.left) {
      delta = -delta;
    }
    final bounded = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (delta == 0 || bounded == position.pixels) return;
    final before = position.pixels;
    // Scrollable claims the signal before its chrome receives it. Replace
    // that synchronous step before the next painted frame, only if this
    // viewport actually consumed it (nested scroll views remain independent).
    scheduleMicrotask(() {
      if (!mounted || _position != position || position.pixels == before) {
        return;
      }
      final consumed = position.pixels - before;
      position.jumpTo(before);
      if (_velocity.sign != delta.sign) _velocity = 0;
      _velocity += ScrollMotion.wheelVelocity(consumed);
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerSignal: _wheel,
    onPointerDown: (_) => _stop(),
    child: widget.child,
  );
}
