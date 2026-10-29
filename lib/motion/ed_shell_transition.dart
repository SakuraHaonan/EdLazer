import 'package:flutter/widgets.dart';

import 'ed_motion.dart';

/// Shell page transition.
///
/// Replaces the cross-fade. Tab changes fade through; drill-in uses a short
/// shared axis. The outgoing page is a frozen layer ([TickerMode] off,
/// [RepaintBoundary]) and is dropped once its opacity hits zero, so the GPU
/// is not blending two browse trees for the whole spring.
///
/// The clock lives here, not on a second controller mirrored from an
/// [AnimatedSwitcher]. [onSettled] fires when the spring rests so the shell
/// can let the backdrop mesh run again.
class EdShellTransition extends StatefulWidget {
  const EdShellTransition({
    super.key,
    required this.switchKey,
    required this.pattern,
    required this.direction,
    required this.travel,
    required this.enabled,
    required this.holdIncoming,
    required this.onSettled,
    required this.onAbandoned,
    required this.child,
  });

  final String switchKey;
  final EdPattern pattern;
  final int direction;
  final double travel;
  final bool enabled;

  /// Pauses the incoming page's own tickers while the spring runs.
  final bool holdIncoming;
  final VoidCallback onSettled;
  final VoidCallback onAbandoned;
  final Widget child;

  @override
  State<EdShellTransition> createState() => _EdShellTransitionState();
}

class _EdShellTransitionState extends State<EdShellTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  Widget? _outgoing;
  String? _outgoingKey;
  EdPattern _pattern = EdPattern.through;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: EdMotion.settleDuration,
      value: 1,
    )..addStatusListener(_onStatus);
    _pattern = widget.pattern;
    _direction = widget.direction;
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) widget.onSettled();
  }

  @override
  void didUpdateWidget(EdShellTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.switchKey == oldWidget.switchKey) return;
    _outgoing = oldWidget.child;
    _outgoingKey = oldWidget.switchKey;
    _pattern = widget.pattern;
    _direction = widget.direction == 0 ? 1 : widget.direction;
    if (!widget.enabled) {
      _outgoing = null;
      _clock.value = 1;
      return;
    }
    _clock.forward(from: 0);
  }

  @override
  void dispose() {
    widget.onAbandoned();
    _clock
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget incoming = TickerMode(
      enabled: !widget.holdIncoming,
      child: KeyedSubtree(
        key: ValueKey<String>('ed-in-${widget.switchKey}'),
        child: widget.child,
      ),
    );
    return AnimatedBuilder(
      animation: _clock,
      builder: (BuildContext context, Widget? child) {
        final double t = EdMotion.curve.transform(_clock.value);
        final double outOpacity = _pattern == EdPattern.through
            ? EdMotion.throughOut(t)
            : EdMotion.axisOut(t);
        final bool showOutgoing =
            _outgoing != null && outOpacity > 0.001 && t < 1;
        return Stack(
          fit: StackFit.expand,
          alignment: Alignment.topCenter,
          children: <Widget>[
            if (showOutgoing)
              TickerMode(
                enabled: false,
                child: IgnorePointer(
                  child: ExcludeSemantics(
                    child: _layer(
                      key: ValueKey<String>('out-$_outgoingKey'),
                      opacity: outOpacity,
                      slide: _slide(outgoing: true, opacity: outOpacity),
                      child: _outgoing!,
                    ),
                  ),
                ),
              ),
            _layer(
              opacity: _pattern == EdPattern.through
                  ? EdMotion.throughIn(t)
                  : EdMotion.axisIn(t),
              slide: _slide(
                outgoing: false,
                opacity: _pattern == EdPattern.through
                    ? EdMotion.throughIn(t)
                    : EdMotion.axisIn(t),
              ),
              child: child!,
            ),
          ],
        );
      },
      child: incoming,
    );
  }

  Offset _slide({required bool outgoing, required double opacity}) {
    final double span = widget.travel * _direction;
    final double amount = outgoing ? (1 - opacity) : (1 - opacity);
    final double sign = outgoing ? -0.55 : 1;
    final double scale = _pattern == EdPattern.through ? 0.4 : 1;
    return Offset(sign * span * scale * amount, 0);
  }

  Widget _layer({
    Key? key,
    required double opacity,
    required Offset slide,
    required Widget child,
  }) {
    final double painted = opacity.clamp(0.0, 1.0);
    return FractionalTranslation(
      key: key,
      translation: slide,
      child: Opacity(
        opacity: painted,
        child: RepaintBoundary(child: child),
      ),
    );
  }
}

/// Fade-through for a single slot (cover art, a player pane, a notice).
///
/// The child must change identity via [switchKey]. Both layers are repaint
/// boundaries; the outgoing one is unmounted as soon as it is transparent.
class EdFadeThrough extends StatefulWidget {
  const EdFadeThrough({
    super.key,
    required this.switchKey,
    required this.child,
    this.direction = 1,
    this.travel = 0.04,
    this.duration = EdMotion.throughDuration,
  });

  final Object switchKey;
  final Widget child;
  final int direction;
  final double travel;
  final Duration duration;

  @override
  State<EdFadeThrough> createState() => _EdFadeThroughState();
}

class _EdFadeThroughState extends State<EdFadeThrough>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock;
  Widget? _outgoing;
  Object? _outgoingKey;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _clock = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 1,
    );
  }

  @override
  void didUpdateWidget(EdFadeThrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    _clock.duration = widget.duration;
    if (widget.switchKey == oldWidget.switchKey) return;
    _outgoing = oldWidget.child;
    _outgoingKey = oldWidget.switchKey;
    _direction = widget.direction == 0 ? 1 : widget.direction;
    if (EdMotion.reducedOf(context) || widget.duration == Duration.zero) {
      _outgoing = null;
      _clock.value = 1;
      return;
    }
    _clock.forward(from: 0);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget incoming = KeyedSubtree(
      key: ValueKey<String>('ed-in-${widget.switchKey}'),
      child: widget.child,
    );
    return AnimatedBuilder(
      animation: _clock,
      builder: (BuildContext context, Widget? child) {
        final double t = EdMotion.curve.transform(_clock.value);
        final double out = EdMotion.throughOut(t);
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (_outgoing != null && out > 0.001 && t < 1)
              _layer(
                key: ValueKey<Object>('out-$_outgoingKey'),
                opacity: out,
                dx: -widget.travel * _direction * 0.4 * (1 - out),
                child: _outgoing!,
              ),
            _layer(
              opacity: EdMotion.throughIn(t),
              dx: widget.travel * _direction * (1 - EdMotion.throughIn(t)),
              child: child!,
            ),
          ],
        );
      },
      child: incoming,
    );
  }

  Widget _layer({
    Key? key,
    required double opacity,
    required double dx,
    required Widget child,
  }) {
    return FractionalTranslation(
      key: key,
      translation: Offset(dx, 0),
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: RepaintBoundary(child: child),
      ),
    );
  }
}
