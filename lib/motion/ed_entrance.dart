import 'package:flutter/widgets.dart';

import 'ed_motion.dart';

/// One-shot arrival for content that appears inside an already-visible page.
///
/// A comment list or a notice fades and rises a few pixels on the shared
/// spring. The whole block is one layer — rows are not staggered, because a
/// per-row entrance rebuilds the list on every tick.
class EdEntrance extends StatelessWidget {
  const EdEntrance({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.duration = EdMotion.entranceDuration,
  });

  final Widget child;
  final Axis axis;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final bool reduced = EdMotion.reducedOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: reduced ? 1 : 0, end: 1),
      duration: reduced ? Duration.zero : duration,
      curve: EdMotion.curve,
      child: child,
      builder: (BuildContext context, double t, Widget? child) {
        final double remain = 1 - t;
        final Offset slide = axis == Axis.horizontal
            ? Offset(remain * EdMotion.travel, 0)
            : Offset(0, remain * EdMotion.travel);
        return FractionalTranslation(
          translation: slide,
          child: Opacity(
            opacity: t.clamp(0.0, 1.0),
            child: RepaintBoundary(child: child),
          ),
        );
      },
    );
  }
}
