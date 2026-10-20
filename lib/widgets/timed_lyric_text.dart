// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../animation/lyric_word_motion.dart';
import '../data/lyrics.dart';

/// Word-timed lyric line.
///
/// Painting is deliberately batched: the base line is painted once, every fully
/// sung word is painted once through a glyph clip, and only the one word the
/// playhead is currently crossing needs per-glyph mask layers. The previous
/// implementation repainted the whole line and allocated a layer for *every*
/// glyph, which made a 20-character line cost ~20 save layers per frame — fine
/// at 60 fps on a desktop GPU, not fine inside a 120 fps budget.
class TimedLyricText extends StatefulWidget {
  const TimedLyricText({
    super.key,
    required this.line,
    required this.style,
    required this.active,
    required this.position,
    required this.repaint,
  });

  final LyricLine line;
  final TextStyle style;
  final bool active;
  final Duration Function() position;
  final Listenable repaint;

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
      builder: (BuildContext context, BoxConstraints box) {
        final TextScaler scaler = MediaQuery.textScalerOf(context);
        final Locale? locale = Localizations.maybeLocaleOf(context);
        final Object key = (
          widget.line,
          widget.style,
          box.maxWidth,
          scaler,
          locale,
        );
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
                active: widget.active,
                repaint: widget.repaint,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Glyph {
  const _Glyph({
    required this.character,
    required this.rect,
    required this.clip,
    required this.start,
    required this.end,
  });

  /// Index of the character inside its word.
  final int character;
  final Rect rect;
  final Rect clip;

  /// Horizontal span inside the word's own (possibly wrapped) flow.
  final double start;
  final double end;
}

class _WordGlyphs {
  _WordGlyphs({
    required this.word,
    required this.glyphs,
    required this.path,
    required this.bounds,
    required this.totalWidth,
    required this.emphasized,
    required this.last,
  });

  final LyricWord word;
  final List<_Glyph> glyphs;
  final Path path;
  final Rect bounds;
  final double totalWidth;
  final bool emphasized;
  final bool last;

  double get startMs => word.start.inMicroseconds / 1000;
  double get durationMs => word.duration.inMicroseconds / 1000;
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
      final LyricWord word = line.words[wi];
      final int wordStart = offset;
      final int wordEnd = offset + word.text.length;
      final List<Rect> rects = bright
          .getBoxesForSelection(
            TextSelection(baseOffset: wordStart, extentOffset: wordEnd),
          )
          .map((TextBox box) => box.toRect())
          .toList();
      final double totalWidth = rects.fold<double>(
        0,
        (double sum, Rect rect) => sum + rect.width,
      );
      final int trimmedLength = word.text.trim().characters.length;
      final bool emphasized =
          word.duration >= const Duration(milliseconds: 1000) &&
          (_WordPainter.cjk.hasMatch(word.text) ||
              trimmedLength > 1 && trimmedLength <= 7);
      final List<_Glyph> glyphs = <_Glyph>[];
      final Path wordPath = Path();
      var consumed = 0.0;
      var charIndex = 0;
      offset = wordStart;
      for (final String character in word.text.characters) {
        final int end = offset + character.length;
        for (final Rect rect
            in bright
                .getBoxesForSelection(
                  TextSelection(baseOffset: offset, extentOffset: end),
                )
                .map((TextBox box) => box.toRect())) {
          if (rect.right <= rect.left || rect.height <= 0) continue;
          final Rect clip = Rect.fromLTRB(
            rect.left,
            rect.top - fontSize * .15,
            rect.right,
            rect.bottom + fontSize * .15,
          );
          baseClip.addRect(clip);
          wordPath.addRect(clip);
          glyphs.add(
            _Glyph(
              character: charIndex,
              rect: rect,
              clip: clip,
              start: consumed,
              end: consumed + rect.width,
            ),
          );
          consumed += rect.width;
        }
        offset = end;
        charIndex++;
      }
      if (glyphs.isEmpty) continue;
      words.add(
        _WordGlyphs(
          word: word,
          glyphs: glyphs,
          path: wordPath,
          bounds: wordPath.getBounds(),
          totalWidth: totalWidth <= 0 ? consumed : totalWidth,
          emphasized: emphasized,
          last: wi == line.words.length - 1,
        ),
      );
      offset = wordEnd;
    }
  }

  final LyricLine line;
  late final TextPainter bright;
  late final TextPainter dim;
  late final double fontSize;
  final Path baseClip = Path();
  final List<_WordGlyphs> words = <_WordGlyphs>[];

  void dispose() {
    bright.dispose();
    dim.dispose();
  }
}

class _WordPainter extends CustomPainter {
  _WordPainter({
    required this.layout,
    required this.position,
    required this.active,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _WordLayout layout;
  final Duration Function() position;
  final bool active;

  static final RegExp cjk = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
  );

  static final Paint _maskPaint = Paint()..blendMode = BlendMode.dstIn;

  @override
  void paint(Canvas canvas, Size size) {
    // Inactive lines are painted as one clipped paragraph: no per-frame work,
    // no layers, and the row's ColorFilter still animates its emphasis.
    if (!active) {
      canvas.save();
      canvas.clipPath(layout.baseClip);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
      return;
    }

    final double nowMs = position().inMicroseconds / 1000.0;

    // Intro: the first line is focused but no word has started yet. Show the
    // whole line at full brightness rather than its unsung 28% base.
    if (layout.words.isEmpty || nowMs < layout.words.first.startMs) {
      canvas.save();
      canvas.clipPath(layout.baseClip);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
      return;
    }

    // Unsung text sits under the highlight at 28% opacity.
    canvas.save();
    canvas.clipPath(layout.baseClip);
    layout.dim.paint(canvas, Offset.zero);
    canvas.restore();

    final Path sung = Path();
    _WordGlyphs? crossing;
    for (final _WordGlyphs word in layout.words) {
      final double elapsed = nowMs - word.startMs;
      if (elapsed < word.durationMs) {
        if (elapsed > 0) crossing = word;
        break;
      }
      sung.addPath(word.path, Offset.zero);
    }

    if (sung.getBounds().isEmpty == false) {
      canvas.save();
      canvas.clipPath(sung);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }
    if (crossing != null) _paintWord(canvas, crossing, nowMs);
  }

  void _paintWord(Canvas canvas, _WordGlyphs word, double nowMs) {
    final double elapsed = nowMs - word.startMs;
    final double duration = math.max(1, word.durationMs);
    final double boundary =
        (elapsed / duration).clamp(0.0, 1.0) * word.totalWidth;
    final double fade = math.max(1.0, word.glyphs.first.rect.height * .5);

    for (final _Glyph glyph in word.glyphs) {
      if (glyph.start >= boundary) break;
      final bool completed = glyph.end <= boundary;
      // A glyph keeps its pop for a short beat after the mask crosses it, then
      // settles. Only running glyphs need the transform path.
      final double glyphEndMs =
          word.startMs + duration * (glyph.end / math.max(1, word.totalWidth));
      final bool settling = !completed || nowMs - glyphEndMs < 420;
      final LyricWordMotion motion = word.emphasized
          ? LyricWordMotion.emphasized(
              elapsed,
              duration,
              glyph.character,
              word.word.text.characters.length,
              last: word.last,
            )
          : LyricWordMotion.ordinary(elapsed, duration);
      final bool transform =
          settling && (motion.scale != 1 || motion.xEm != 0 || motion.yEm != 0);
      final bool glow = settling && motion.glow > .001;

      canvas.save();
      if (transform) {
        final Rect rect = glyph.rect;
        canvas.translate(
          motion.xEm * layout.fontSize,
          motion.yEm * layout.fontSize,
        );
        canvas.translate(rect.center.dx, rect.center.dy);
        canvas.scale(motion.scale);
        canvas.translate(-rect.center.dx, -rect.center.dy);
      }
      canvas.clipRect(glyph.clip);
      if (glow) {
        canvas.saveLayer(
          glyph.clip,
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
      if (completed) {
        layout.bright.paint(canvas, Offset.zero);
      } else {
        final double boundaryX = glyph.rect.left + (boundary - glyph.start);
        canvas.saveLayer(glyph.clip, Paint());
        layout.bright.paint(canvas, Offset.zero);
        canvas.drawRect(
          glyph.clip,
          _maskPaint
            ..shader = ui.Gradient.linear(
              Offset(boundaryX - fade, 0),
              Offset(boundaryX + fade, 0),
              <Color>[Colors.white, Colors.transparent],
            ),
        );
        canvas.restore();
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _WordPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.position != position ||
      oldDelegate.active != active;
}
