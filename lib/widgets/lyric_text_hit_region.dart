import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Match the painted lines, including short wrapped lines, instead of giving
/// every lyric the full width of its row as a tap target.
class LyricTextHitRegion extends SingleChildRenderObjectWidget {
  const LyricTextHitRegion({
    super.key,
    required this.text,
    required this.style,
    required super.child,
  });
  final String text;
  final TextStyle style;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLyricTextHitRegion(
        text,
        style,
        MediaQuery.textScalerOf(context),
        Localizations.maybeLocaleOf(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) => (renderObject as _RenderLyricTextHitRegion).configure(
    text,
    style,
    MediaQuery.textScalerOf(context),
    Localizations.maybeLocaleOf(context),
  );
}

class _RenderLyricTextHitRegion extends RenderProxyBox {
  _RenderLyricTextHitRegion(
    this._text,
    this._style,
    this._scaler,
    this._locale,
  );
  String _text;
  TextStyle _style;
  TextScaler _scaler;
  Locale? _locale;
  TextPainter? _painter;
  double? _width;
  List<Rect> _boxes = const [];

  void configure(
    String text,
    TextStyle style,
    TextScaler scaler,
    Locale? locale,
  ) {
    if (_text == text &&
        _style == style &&
        _scaler == scaler &&
        _locale == locale) {
      return;
    }
    _text = text;
    _style = style;
    _scaler = scaler;
    _locale = locale;
    _painter?.dispose();
    _painter = null;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (_painter != null && _width == size.width) return;
    _width = size.width;
    _painter?.dispose();
    final painter = _painter = TextPainter(
      text: TextSpan(text: _text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: _scaler,
      locale: _locale,
    )..layout(maxWidth: size.width);
    _boxes = painter
        .getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: _text.trimRight().length),
        )
        .map((box) => box.toRect())
        .where((box) => !box.isEmpty)
        .toList();
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) =>
      _boxes.any((box) => box.contains(position)) &&
      super.hitTest(result, position: position);

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }
}
