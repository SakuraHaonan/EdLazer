import 'package:flutter/material.dart';

import '../data/models.dart';
import 'plate_art.dart';

/// Forward: outgoing cover moves right, incoming cover arrives from the right.
/// Metadata refreshes retain the identity and do not replay the transition.
class AnimatedTrackCover extends StatelessWidget {
  const AnimatedTrackCover({
    super.key,
    required this.track,
    required this.direction,
  });
  final Track track;
  final int direction;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedSwitcher(
      duration: const Duration(milliseconds: 480),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SlideTransition(
        position: Tween<Offset>(
          begin: Offset(direction < 0 ? -1 : 1, 0),
          end: Offset.zero,
        ).animate(animation),
        // The slide only moves a cached layer; the old implementation moved
        // the full-size artwork pixels every frame.
        child: RepaintBoundary(child: child),
      ),
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [
          for (final old in previous)
            ExcludeSemantics(child: IgnorePointer(child: old)),
          ?current,
        ],
      ),
      child: PlateArt(
        key: ValueKey(track.id),
        seed: track.coverSeed,
        coverUrl: track.coverUrl,
        radius: BorderRadius.zero,
      ),
    ),
  );
}
