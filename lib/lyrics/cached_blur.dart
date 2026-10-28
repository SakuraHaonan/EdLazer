import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A Gaussian blur that is rasterized once and then drawn as a bitmap.
///
/// Impeller has no raster cache: an `ImageFiltered` row re-runs its blur on
/// every composited frame, even when neither the row nor its sigma changed.
/// With word-timed lyrics the sheet composites every vsync, so ten blurred
/// rows cost ten blur passes per frame for a picture that never changes.
///
/// This boundary paints its child live (with a blur layer) only on frames
/// where the child itself repainted; once the row is quiet it is captured,
/// blurred once at reduced resolution and from then on drawn with a single
/// `drawImageRect`. A new raster is only made when the quantized [sigma]
/// changes, and at most [rasterBudget] rows are rasterized per frame.
class CachedBlur extends SingleChildRenderObjectWidget {
  const CachedBlur({
    super.key,
    required this.sigma,
    required this.devicePixelRatio,
    this.coarse = false,
    super.child,
  });

  /// Already quantized by the caller.
  final double sigma;
  final double devicePixelRatio;

  /// Rasterize at an even lower resolution (reduced quality tier).
  final bool coarse;

  static const int rasterBudget = 3;

  @override
  RenderCachedBlur createRenderObject(BuildContext context) => RenderCachedBlur(
    sigma: sigma,
    devicePixelRatio: devicePixelRatio,
    coarse: coarse,
  );

  @override
  void updateRenderObject(BuildContext context, RenderCachedBlur renderObject) {
    renderObject
      ..sigma = sigma
      ..devicePixelRatio = devicePixelRatio
      ..coarse = coarse;
  }
}

class _CaptureContext extends PaintingContext {
  _CaptureContext(super.containerLayer, super.estimatedBounds);
  void finish() => stopRecordingIfNeeded();
}

class RenderCachedBlur extends RenderProxyBox {
  RenderCachedBlur({
    required this._sigma,
    required this._devicePixelRatio,
    this._coarse = false,
  });

  /// Rows rasterized and live blur layers painted, for tests and profiling.
  static int debugRasterCount = 0;
  static int debugLivePaintCount = 0;
  static int debugCachedPaintCount = 0;

  static int _frame = 0;
  static bool _frameHook = false;
  static int _budgetFrame = -1;
  static int _budgetUsed = 0;

  static bool _takeBudget() {
    if (!_frameHook) {
      _frameHook = true;
      // Registered after the rendering pipeline, so it runs once per frame
      // after paint and separates one frame's budget from the next.
      SchedulerBinding.instance.addPersistentFrameCallback((_) => _frame++);
    }
    if (_budgetFrame != _frame) {
      _budgetFrame = _frame;
      _budgetUsed = 0;
    }
    if (_budgetUsed >= CachedBlur.rasterBudget) return false;
    _budgetUsed++;
    return true;
  }

  double _sigma;
  set sigma(double value) {
    if (value == _sigma) return;
    _sigma = value;
    _markSelf();
  }

  double _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (value == _devicePixelRatio) return;
    _devicePixelRatio = value;
    _dropImage();
    _markSelf();
  }

  bool _coarse;
  set coarse(bool value) {
    if (value == _coarse) return;
    _coarse = value;
    _dropImage();
    _markSelf();
  }

  bool _selfMarking = false;
  bool _contentDirty = true;
  bool _retryScheduled = false;
  ui.Image? _image;
  double _imageSigma = 0;
  Size _imageSize = Size.zero;
  double _imageScale = 1;
  double _imagePad = 0;
  final LayerHandle<ImageFilterLayer> _live = LayerHandle<ImageFilterLayer>();

  @override
  bool get isRepaintBoundary => true;

  void _markSelf() {
    _selfMarking = true;
    markNeedsPaint();
    _selfMarking = false;
  }

  @override
  void markNeedsPaint() {
    // Anything but our own sigma/retry marks means the child's pixels
    // changed (a descendant repainted, or we were laid out again).
    if (!_selfMarking) _contentDirty = true;
    super.markNeedsPaint();
  }

  double _scaleFor(double sigma) {
    // A blurred row has no detail above ~1/sigma cycles per pixel, so it can
    // be rasterized well below device resolution without a visible change.
    double f = sigma >= 3
        ? .4
        : sigma >= 1.5
        ? .6
        : .85;
    if (_coarse) f *= .6;
    return math.max(.2, _devicePixelRatio * f);
  }

  void _dropImage() {
    _image?.dispose();
    _image = null;
  }

  void _scheduleRetry() {
    if (_retryScheduled) return;
    _retryScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _retryScheduled = false;
      if (attached) _markSelf();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? box = child;
    final bool contentDirty = _contentDirty;
    _contentDirty = false;
    if (box == null) return;
    if (_sigma <= 0 || size.isEmpty) {
      _dropImage();
      _live.layer = null;
      context.paintChild(box, offset);
      return;
    }
    if (contentDirty || _imageSize != size) _dropImage();
    final bool fresh = _image != null && _imageSigma == _sigma;
    if (!fresh && !contentDirty && _takeBudget()) _rasterize(box);
    final ui.Image? image = _image;
    if (image != null) {
      _live.layer = null;
      debugCachedPaintCount++;
      context.canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        Rect.fromLTWH(
          offset.dx - _imagePad,
          offset.dy - _imagePad,
          image.width / _imageScale,
          image.height / _imageScale,
        ),
        Paint()..filterQuality = FilterQuality.medium,
      );
      // A stale sigma is drawn for at most a frame or two while the budget
      // catches up.
      if (_imageSigma != _sigma) _scheduleRetry();
      return;
    }
    debugLivePaintCount++;
    final ImageFilterLayer layer = _live.layer ?? ImageFilterLayer();
    layer.imageFilter = ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma);
    _live.layer = layer;
    context.pushLayer(layer, super.paint, offset);
    _scheduleRetry();
  }

  void _rasterize(RenderBox box) {
    final double scale = _scaleFor(_sigma);
    final Rect bounds = Offset.zero & size;
    final OffsetLayer root = OffsetLayer();
    final _CaptureContext capture = _CaptureContext(root, bounds);
    capture.paintChild(box, Offset.zero);
    capture.finish();
    final ui.Image raw = root.toImageSync(bounds, pixelRatio: scale);
    root.removeAllChildren();
    root.dispose();
    // Leave room for the Gaussian tail around the row.
    final double pad = (_sigma * 3).ceilToDouble();
    final int width = ((size.width + pad * 2) * scale).ceil();
    final int height = ((size.height + pad * 2) * scale).ceil();
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final double s = _sigma * scale;
    canvas.drawImage(
      raw,
      Offset(pad * scale, pad * scale),
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: s,
          sigmaY: s,
          tileMode: TileMode.decal,
        ),
    );
    final ui.Picture picture = recorder.endRecording();
    final ui.Image blurred = picture.toImageSync(
      math.max(1, width),
      math.max(1, height),
    );
    picture.dispose();
    raw.dispose();
    _dropImage();
    _image = blurred;
    _imageSigma = _sigma;
    _imageSize = size;
    _imageScale = width / (size.width + pad * 2);
    _imagePad = pad;
    debugRasterCount++;
  }

  @override
  void detach() {
    _dropImage();
    super.detach();
  }

  @override
  void dispose() {
    _dropImage();
    _live.layer = null;
    super.dispose();
  }
}
