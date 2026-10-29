import 'package:flutter/material.dart';

import '../data/models.dart';
import '../motion/ed_motion.dart';
import '../motion/ed_shell_transition.dart';
import 'plate_art.dart';

/// A track change fades the next cover through the previous one.
///
/// Fade-through, not a cross-fade and not a carousel slide: the outgoing
/// plate is gone before the incoming one is opaque, and [direction] nudges
/// the shared axis (next track enters from the right, previous from the
/// left). Both plates sit in their own repaint boundary.
class AnimatedTrackCover extends StatelessWidget {
  const AnimatedTrackCover({
    super.key,
    required this.track,
    required this.direction,
  });

  final Track track;
  final int direction;

  @override
  Widget build(BuildContext context) {
    final int axis = direction == 0 ? 1 : direction.sign;
    return ClipRect(
      child: EdFadeThrough(
        switchKey: track.id,
        direction: axis,
        travel: EdMotion.travel,
        duration: EdMotion.durationOf(context, EdMotion.throughDuration),
        child: PlateArt(
          key: ValueKey<String>(track.id),
          seed: track.coverSeed,
          coverUrl: track.coverUrl,
          radius: BorderRadius.zero,
        ),
      ),
    );
  }
}
