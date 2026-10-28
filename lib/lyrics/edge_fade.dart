import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// Fade the filtered result, including its blur halo, before clipping it.
/// Horizontal gutters leave room for the first/last glyph's Gaussian tail.
class LyricEdgeFade extends StatelessWidget {
  const LyricEdgeFade({
    super.key,
    required this.child,
    required this.verticalExtent,
    this.horizontal = true,
  });

  static const horizontalExtent = 18.0;
  final Widget child;
  final double verticalExtent;

  /// Fades the left/right edges as well.
  ///
  /// Both fades share one ShaderMask (one full-pane offscreen pass): the
  /// mask is a cached image of the two gradients multiplied together.
  final bool horizontal;

  ui.Shader _shader(Rect bounds, {required bool vertical}) {
    final length = vertical ? bounds.height : bounds.width;
    final extent = vertical ? verticalExtent : horizontalExtent;
    final fraction = length <= 0 ? 0.0 : math.min(0.24, extent / length);
    // Smoothstep samples avoid a visible change in slope where the fade begins.
    const levels = [0, 11, 40, 81, 128, 174, 215, 244, 255];
    final colors = [
      for (final alpha in levels) ui.Color.fromARGB(alpha, 255, 255, 255),
      for (final alpha in levels.reversed)
        ui.Color.fromARGB(alpha, 255, 255, 255),
    ];
    final stops = [
      for (var i = 0; i < levels.length; i++)
        fraction * i / (levels.length - 1),
      for (var i = 0; i < levels.length; i++)
        1 - fraction + fraction * i / (levels.length - 1),
    ];
    return ui.Gradient.linear(
      vertical ? bounds.topCenter : bounds.centerLeft,
      vertical ? bounds.bottomCenter : bounds.centerRight,
      colors,
      stops,
    );
  }

  /// Cached product of the vertical and horizontal fades, so a compact
  /// pane needs one offscreen mask pass instead of two nested ones.
  static ui.Image? _maskImage;
  static (int, int, double)? _maskKey;
  static ui.ImageShader? _maskShader;
  static Rect? _maskShaderBounds;

  ui.Shader _combined(Rect bounds) {
    if (bounds.isEmpty) return _shader(bounds, vertical: true);
    // Rebuild the (half resolution) mask only when the pane size moves by
    // more than a few pixels; between rebuilds it is stretched, which is
    // invisible on a smooth 18-30 px fade.
    final key = (
      (bounds.width / 6).round(),
      (bounds.height / 6).round(),
      (verticalExtent * 2).roundToDouble(),
    );
    if (_maskImage == null || _maskKey != key) {
      final size = Size(bounds.width, bounds.height);
      final int w = math.max(2, (size.width / 2).ceil());
      final int h = math.max(2, (size.height / 2).ceil());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)..scale(w / size.width, h / size.height);
      final Rect full = Offset.zero & size;
      canvas.drawRect(full, Paint()..shader = _shader(full, vertical: true));
      canvas.drawRect(
        full,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = _shader(full, vertical: false),
      );
      final picture = recorder.endRecording();
      _maskImage = picture.toImageSync(w, h);
      picture.dispose();
      _maskKey = key;
      _maskShader = null;
    }
    if (_maskShader == null || _maskShaderBounds != bounds) {
      final image = _maskImage!;
      _maskShader = ui.ImageShader(
        image,
        TileMode.clamp,
        TileMode.clamp,
        (Matrix4.diagonal3Values(
          bounds.width / image.width,
          bounds.height / image.height,
          1,
        )..setTranslationRaw(bounds.left, bounds.top, 0)).storage,
        filterQuality: FilterQuality.medium,
      );
      _maskShaderBounds = bounds;
    }
    return _maskShader!;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) =>
            horizontal ? _combined(bounds) : _shader(bounds, vertical: true),
        child: child,
      ),
    );
  }
}
