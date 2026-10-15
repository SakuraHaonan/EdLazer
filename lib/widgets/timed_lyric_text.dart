// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../animation/lyric_word_motion.dart';
import '../data/lyrics.dart';

class TimedLyricText extends StatefulWidget {
  const TimedLyricText({
    super.key,
    required this.line,
    required this.style,
    required this.active,
    required this.position,
    required this.repaint,
    this.emphasis,
  });
  final LyricLine line;
  final TextStyle style;
  final bool active;
  final Duration Function() position;
  final Listenable repaint;
  final double Function()? emphasis;
  @override
  State<TimedLyricText> createState() => _TimedLyricTextState();
}

class _TimedLyricTextState extends State<TimedLyricText> {
  _WordLayout? _layout;
  Object? _layoutKey;
  @override
  void dispose() {
    _layout?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final scaler = MediaQuery.textScalerOf(context);
        final locale = Localizations.maybeLocaleOf(context);
        final key = (widget.line, widget.style, box.maxWidth, scaler, locale);
        if (_layoutKey != key) {
          _layout?.dispose();
          _layout = _WordLayout(
            widget.line,
            widget.style,
            box.maxWidth,
            scaler,
            locale,
          );
          _layoutKey = key;
        }
        return Semantics(
          label: widget.line.text,
          child: ExcludeSemantics(
            child: CustomPaint(
              size: Size(box.maxWidth, _layout!.bright.height),
              painter: _WordPainter(
                layout: _layout!,
                position: widget.position,
                emphasis: widget.emphasis ?? () => widget.active ? 1.0 : 0.0,
                repaint: widget.repaint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Segment {
  const _Segment(
    this.word,
    this.wordIndex,
    this.character,
    this.count,
    this.rect,
    this.wordRects,
  );
  final LyricWord word;
  final int wordIndex, character, count;
  final Rect rect;
  final List<Rect> wordRects;
}

class _WordLayout {
  _WordLayout(
    this.line,
    TextStyle style,
    double width,
    TextScaler scaler,
    Locale? locale,
  ) {
    bright = TextPainter(
      text: TextSpan(text: line.text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    dim = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(
          color: (style.color ?? Colors.black).withValues(alpha: .28),
        ),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    fontSize = scaler.scale(style.fontSize ?? 22);
    var offset = 0;
    for (var wi = 0; wi < line.words.length; wi++) {
      final word = line.words[wi];
      final rects = bright
          .getBoxesForSelection(
            TextSelection(
              baseOffset: offset,
              extentOffset: offset + word.text.length,
            ),
          )
          .map((box) => box.toRect())
          .toList();
      final chars = word.text.characters.toList();
      for (var ci = 0; ci < chars.length; ci++) {
        final end = offset + chars[ci].length;
        for (final box in bright.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: end),
        )) {
          if (box.right > box.left) {
            segments.add(
              _Segment(word, wi, ci, chars.length, box.toRect(), rects),
            );
          }
        }
        offset = end;
      }
    }
  }
  final LyricLine line;
  late final TextPainter bright, dim;
  late final double fontSize;
  final List<_Segment> segments = [];
  void dispose() {
    bright.dispose();
    dim.dispose();
  }
}

class _WordPainter extends CustomPainter {
  _WordPainter({
    required this.layout,
    required this.position,
    required this.emphasis,
    required Listenable repaint,
  }) : super(repaint: repaint);
  final _WordLayout layout;
  final Duration Function() position;
  final double Function() emphasis;
  static final _cjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]');
  @override
  void paint(Canvas canvas, Size size) {
    final focus = emphasis().clamp(0.0, 1.0);
    if (focus < 1) {
      canvas.saveLayer(
        null,
        Paint()..color = Colors.white.withValues(alpha: 1 - focus),
      );
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }
    if (focus <= 0) return;
    // Retain the word painter while the row exits; fade its emphasis using
    // the same spring as the row's scale and color instead of swapping to Text.
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: focus),
    );
    final now = position().inMicroseconds / 1000;
    for (final segment in layout.segments) {
      final word = segment.word;
      final elapsed = now - word.start.inMicroseconds / 1000;
      final duration = word.duration.inMicroseconds / 1000;
      final emphasize =
          duration >= 1000 &&
          (_cjk.hasMatch(word.text) ||
              word.text.trim().characters.length > 1 &&
                  word.text.trim().characters.length <= 7);
      final motion = emphasize
          ? LyricWordMotion.emphasized(
              elapsed,
              duration,
              segment.character,
              segment.count,
              last: segment.wordIndex == layout.line.words.length - 1,
            )
          : LyricWordMotion.ordinary(elapsed, duration);
      final rect = segment.rect;
      var consumed = 0.0;
      var wordLeft = rect.left;
      for (final part in segment.wordRects) {
        if ((part.top - rect.top).abs() < 1 &&
            rect.left >= part.left - 1 &&
            rect.right <= part.right + 1) {
          wordLeft = part.left;
          break;
        }
        consumed += part.width;
      }
      final total = segment.wordRects.fold(0.0, (sum, box) => sum + box.width);
      final boundary =
          wordLeft +
          LyricWordMotion.maskBoundary(elapsed, duration, total) -
          consumed;
      final fade = math.max(1.0, rect.height * .5);
      canvas.save();
      canvas.translate(
        motion.xEm * layout.fontSize * focus,
        motion.yEm * layout.fontSize * focus,
      );
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.scale(1 + (motion.scale - 1) * focus);
      canvas.translate(-rect.center.dx, -rect.center.dy);
      final clip = Rect.fromLTRB(
        rect.left,
        rect.top - layout.fontSize * .15,
        rect.right,
        rect.bottom + layout.fontSize * .15,
      );
      canvas.clipRect(clip);
      layout.dim.paint(canvas, Offset.zero);
      if (boundary + fade / 2 >= rect.left) {
        canvas.saveLayer(clip, Paint());
        if (motion.glow > .001) {
          canvas.saveLayer(
            clip,
            Paint()
              ..imageFilter = ui.ImageFilter.blur(
                sigmaX: motion.glowRadiusEm * layout.fontSize,
                sigmaY: motion.glowRadiusEm * layout.fontSize,
              )
              ..colorFilter = ColorFilter.mode(
                Colors.white.withValues(alpha: motion.glow),
                BlendMode.srcIn,
              ),
          );
          layout.bright.paint(canvas, Offset.zero);
          canvas.restore();
        }
        layout.bright.paint(canvas, Offset.zero);
        canvas.drawRect(
          clip,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = ui.Gradient.linear(
              Offset(boundary - fade / 2, 0),
              Offset(boundary + fade / 2, 0),
              [Colors.white, Colors.transparent],
            ),
        );
        canvas.restore();
      }
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.position != position ||
      oldDelegate.emphasis != emphasis;
}
