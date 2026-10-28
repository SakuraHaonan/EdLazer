import 'package:flutter/material.dart';

import '../data/models.dart';
import 'plate_art.dart';
import '../theme/tokens.dart';

/// A track change dissolves one cover into the next.
///
/// The old slide read as a carousel; a television at ten feet wants calmer motion.
/// Plain cross-fade on the shared [AppMotion.crossFade] token (200 ms,
/// ease-in-out, no scale). Both children live in their own
/// repaint boundary, so the fade is a compositor operation on cached pixels
/// rather than a re-rasterisation of the artwork every frame.
///
/// Metadata refreshes keep the same [ValueKey] and do not replay the dissolve;
/// [direction] is retained for callers that still report the queue direction,
/// but the transition itself is direction-free.
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
      duration: AppMotion.crossFade,
      switchInCurve: AppMotion.inOutCurve,
      switchOutCurve: AppMotion.inOutCurve,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: RepaintBoundary(child: child),
          ),
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (final Widget old in previous)
            ExcludeSemantics(child: IgnorePointer(child: old)),
          ?current,
        ],
      ),
      child: PlateArt(
        key: ValueKey<String>(track.id),
        seed: track.coverSeed,
        coverUrl: track.coverUrl,
        radius: BorderRadius.zero,
      ),
    ),
  );
}
