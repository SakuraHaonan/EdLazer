// ignore_for_file: prefer_initializing_formals

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Restricts hit testing to the actual painted lyric glyph boxes.
///
/// A lyric row otherwise owns its full rectangular width, which makes the gaps
/// between wrapped short lines steal taps meant for the background or a parent
/// gesture. The custom render object proxies its child but rejects positions
/// that are not inside a laid-out text box.
class LyricTextHitRegion extends SingleChildRenderObjectWidget {
  const LyricTextHitRegion({
    super.key,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.start,
    required super.child,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  RenderObject createRenderObject(BuildContext context) => _LyricHitRender(
    text: text,
    style: style,
    scaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
    direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
    textAlign: textAlign,
  );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _LyricHitRender).configure(
      text: text,
      style: style,
      scaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
      direction: Directionality.maybeOf(context) ?? TextDirection.ltr,
      textAlign: textAlign,
    );
  }
}

class _LyricHitRender extends RenderProxyBox {
  _LyricHitRender({
    required String text,
    required TextStyle style,
    required TextScaler scaler,
    required Locale? locale,
    required TextDirection direction,
    required TextAlign textAlign,
  }) : _text = text,
       _style = style,
       _scaler = scaler,
       _locale = locale,
       _direction = direction,
       _textAlign = textAlign;


  String _text;
  TextStyle _style;
  TextScaler _scaler;
  Locale? _locale;
  TextDirection _direction;
  TextAlign _textAlign;
  TextPainter? _painter;
  List<Rect> _boxes = const <Rect>[];
  double? _measuredWidth;

  void configure({
    required String text,
    required TextStyle style,
    required TextScaler scaler,
    required Locale? locale,
    required TextDirection direction,
    required TextAlign textAlign,
  }) {
    if (_text == text &&
        _style == style &&
        _scaler == scaler &&
        _locale == locale &&
        _direction == direction &&
        _textAlign == textAlign) {
      return;
    }
    _text = text;
    _style = style;
    _scaler = scaler;
    _locale = locale;
    _direction = direction;
    _textAlign = textAlign;
    _painter?.dispose();
    _painter = null;
    _measuredWidth = null;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (size.width <= 0 || size.height <= 0) {
      _boxes = const <Rect>[];
      return;
    }
    if (_painter != null && _measuredWidth == size.width) return;
    _measuredWidth = size.width;
    _painter?.dispose();
    final TextPainter painter = _painter = TextPainter(
      text: TextSpan(text: _text, style: _style),
      textDirection: _direction,
      textScaler: _scaler,
      locale: _locale,
      textAlign: _textAlign,
    )..layout(maxWidth: size.width);
    final int length = _text.trimRight().length;
    _boxes = length <= 0
        ? const <Rect>[]
        : painter
              .getBoxesForSelection(
                TextSelection(baseOffset: 0, extentOffset: length),
              )
              .map((TextBox box) => box.toRect())
              .where((Rect rect) => !rect.isEmpty)
              .toList(growable: false);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!_boxes.any((Rect rect) => rect.contains(position))) return false;
    return super.hitTest(result, position: position);
  }

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }
}
