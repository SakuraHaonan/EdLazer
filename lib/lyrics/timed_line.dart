import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'lyric_document.dart';
import 'word_motion.dart';

/// AMLL-style word-timed lyric line.
///
/// This is a direct port of the reference renderer: every grapheme keeps its
/// own float/emphasis transform for the whole line, the karaoke sweep is a
/// soft horizontal gradient, and the glow is a blurred white clone of the
/// glyph composited underneath the bright text. Completed words keep their
/// upward float instead of snapping back to the baseline.
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

  /// Line focus in `0..1`, driven by the row's scale spring. Without it the
  /// line snaps between dim (`0`) and bright (`1`).
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
      builder: (BuildContext context, BoxConstraints constraints) {
        final TextScaler scaler = MediaQuery.textScalerOf(context);
        final TextDirection direction = Directionality.of(context);
        final Locale? locale = Localizations.maybeLocaleOf(context);
        final Object key = (
          widget.line,
          widget.style,
          constraints.maxWidth,
          scaler,
          direction,
          locale,
        );
        if (_layoutKey != key) {
          _layout?.dispose();
          _layout = _WordLayout(
            widget.line,
            widget.style,
            constraints.maxWidth,
            scaler,
            direction,
            locale,
          );
          _layoutKey = key;
        }
        return Semantics(
          label: widget.line.text,
          child: ExcludeSemantics(
            child: CustomPaint(
              size: Size(constraints.maxWidth, _layout!.bright.height),
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
    this.character,
    this.count,
    this.rect,
    this.wordLeft,
    this.consumed,
    this.totalWidth,
    this.startMs,
    this.durationMs,
    this.glow,
    this.last,
  );

  final int character, count;
  final Rect rect;
  final double wordLeft, consumed, totalWidth, startMs, durationMs;
  final bool glow, last;
}

class _WordLayout {
  _WordLayout(
    this.line,
    TextStyle style,
    double width,
    TextScaler scaler,
    TextDirection direction,
    Locale? locale,
  ) {
    bright = TextPainter(
      text: TextSpan(text: line.text, style: style),
      textDirection: direction,
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
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    fontSize = scaler.scale(style.fontSize ?? 22);
    final List<LyricWord> words = line.words.isNotEmpty
        ? line.words
        : <LyricWord>[
            LyricWord(
              line.time,
              (line.end ?? line.time + const Duration(seconds: 2)) - line.time,
              line.text,
            ),
          ];
    var offset = 0;
    for (var wi = 0; wi < words.length; wi++) {
      final LyricWord word = words[wi];
      final List<Rect> rects = bright
          .getBoxesForSelection(
            TextSelection(
              baseOffset: offset,
              extentOffset: offset + word.text.length,
            ),
          )
          .map((TextBox box) => box.toRect())
          .toList();
      final double totalWidth = rects.fold<double>(
        0,
        (double sum, Rect rect) => sum + rect.width,
      );
      final List<String> chars = word.text.characters.toList();
      final int trimmedLength = word.text.trim().characters.length;
      // Every word uses the long emphasis float for its motion, but only the
      // AMLL-emphasized subset (long syllables/short words) gets the white
      // blurred glow. Short ordinary words float without lighting up.
      final bool glow =
          word.duration >= const Duration(milliseconds: 1000) &&
          (_cjk.hasMatch(word.text) || trimmedLength > 1 && trimmedLength <= 7);
      for (var ci = 0; ci < chars.length; ci++) {
        final int end = offset + chars[ci].length;
        for (final TextBox box in bright.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: end),
        )) {
          if (box.right > box.left) {
            final Rect rect = box.toRect();
            final Rect glyphClip = Rect.fromLTRB(
              rect.left,
              rect.top - fontSize * .15,
              rect.right,
              rect.bottom + fontSize * .15,
            );
            baseClip.addRect(glyphClip);
            // Locate the wrapped line box this glyph belongs to so the
            // gradient sweep is measured from the word's own left edge.
            var consumed = 0.0;
            var wordLeft = rect.left;
            for (final Rect part in rects) {
              if ((part.top - rect.top).abs() < 1 &&
                  rect.left >= part.left - 1 &&
                  rect.right <= part.right + 1) {
                wordLeft = part.left;
                break;
              }
              consumed += part.width;
            }
            segments.add(
              _Segment(
                ci,
                chars.length,
                rect,
                wordLeft,
                consumed,
                totalWidth,
                word.start.inMicroseconds / 1000,
                word.duration.inMicroseconds / 1000,
                glow,
                wi == words.length - 1,
              ),
            );
          }
        }
        offset = end;
      }
    }
  }

  static final RegExp _cjk = RegExp(r'[぀-ヿ㐀-鿿가-힯]');

  final LyricLine line;
  late final TextPainter bright, dim;
  late final double fontSize;
  final List<_Segment> segments = <_Segment>[];
  final Path baseClip = Path();

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

  @override
  void paint(Canvas canvas, Size size) {
    final double focus = emphasis().clamp(0.0, 1.0);
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
    // the same spring as the row's scale and color instead of swapping to
    // plain text.
    canvas.saveLayer(
      null,
      Paint()..color = Colors.white.withValues(alpha: focus),
    );
    final double now = position().inMicroseconds / 1000;
    canvas.save();
    canvas.clipPath(layout.baseClip);
    layout.dim.paint(canvas, Offset.zero);
    canvas.restore();
    for (final _Segment segment in layout.segments) {
      final double elapsed = now - segment.startMs;
      final double duration = segment.durationMs;
      final LyricWordMotion motion = LyricWordMotion.emphasized(
        elapsed,
        duration,
        segment.character,
        segment.count,
        last: segment.last,
        // Ordinary (non-glowing) words settle at the float target instead of
        // peaking and drifting back down like the glowing long syllables.
        holdFloat: !segment.glow,
      );
      final Rect rect = segment.rect;
      final double boundary =
          segment.wordLeft +
          LyricWordMotion.maskBoundary(elapsed, duration, segment.totalWidth) -
          segment.consumed;
      // Width of the soft karaoke edge. AMLL uses half a glyph height so the
      // wipe reads as a moving glow rather than a hard rectangle.
      final double fade = math.max(1.0, rect.height * .5);
      canvas.save();
      canvas.translate(
        motion.xEm * layout.fontSize * focus,
        motion.yEm * layout.fontSize * focus,
      );
      canvas.translate(rect.center.dx, rect.center.dy);
      canvas.scale(1 + (motion.scale - 1) * focus);
      canvas.translate(-rect.center.dx, -rect.center.dy);
      final Rect clip = Rect.fromLTRB(
        rect.left,
        rect.top - layout.fontSize * .15,
        rect.right,
        rect.bottom + layout.fontSize * .15,
      );
      canvas.clipRect(clip);
      if (boundary + fade / 2 >= rect.left) {
        canvas.saveLayer(clip, Paint());
        if (segment.glow && motion.glow > .001) {
          // A blurred, pure-white clone of the glyph, masked by the current
          // emphasis glow strength.
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
              <Color>[Colors.white, Colors.transparent],
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
