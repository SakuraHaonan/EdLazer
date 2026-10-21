import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Softly dissolves its child into transparent edges on all four sides.
///
/// Two nested destination-in shader masks keep the centre fully opaque while
/// the horizontal and vertical ramps multiply at the corners. The mask is
/// applied after blur so the Gaussian halo fades instead of being clipped.
class LyricEdgeFade extends StatelessWidget {
  const LyricEdgeFade({
    super.key,
    required this.child,
    required this.verticalExtent,
  });

  static const double horizontalExtent = 18;
  final Widget child;
  final double verticalExtent;

  ui.Shader _mask(Rect bounds, double extent, bool vertical) {
    final double length = vertical ? bounds.height : bounds.width;
    final double fade = length <= 0
        ? 0.0
        : math.min(.245, extent / length).clamp(0.0, .245);
    return ui.Gradient.linear(
      vertical ? bounds.topCenter : bounds.centerLeft,
      vertical ? bounds.bottomCenter : bounds.centerRight,
      const <Color>[
        Color(0x00FFFFFF),
        Color(0xFFFFFFFF),
        Color(0xFFFFFFFF),
        Color(0x00FFFFFF),
      ],
      <double>[0, fade, 1 - fade, 1],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (Rect bounds) => _mask(bounds, verticalExtent, true),
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (Rect bounds) =>
              _mask(bounds, horizontalExtent, false),
          child: child,
        ),
      ),
    );
  }
}
