import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'lyric_document.dart';
import 'word_motion.dart';

/// AMLL-style word-timed lyric line.
///
/// The renderer uses the actual glyph boxes from a [TextPainter] so wrapping
/// and grapheme clusters stay exact. Completed words paint once through a
/// cached path; only the current word receives the per-character emphasis
/// transform and glow. Inactive rows are a single cached raster.
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
  _LineLayout? _layout;
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
          _layout = _LineLayout(
            line: widget.line,
            style: widget.style,
            width: constraints.maxWidth,
            scaler: scaler,
            direction: direction,
            locale: locale,
          );
          _layoutKey = key;
        }
        return Semantics(
          label: widget.line.text,
          child: ExcludeSemantics(
            child: CustomPaint(
              size: Size(constraints.maxWidth, _layout!.height),
              painter: _TimedLinePainter(
                layout: _layout!,
                active: widget.active,
                position: widget.position,
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
    required this.rect,
    required this.word,
    required this.character,
    required this.startFraction,
    required this.endFraction,
  });

  final Rect rect;
  final _WordRun word;
  final int character;
  final double startFraction;
  final double endFraction;
}

class _WordRun {
  _WordRun({
    required this.word,
    required this.index,
    required this.last,
  });

  final LyricWord word;
  final int index;
  final bool last;
  final List<_Glyph> glyphs = <_Glyph>[];
  final Path path = Path();
  double width = 0;

  static final RegExp _cjk = RegExp(
    r'[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af]',
  );

  int get characterCount => glyphs.length;
  double get startMs => word.start.inMicroseconds / 1000;
  double get endMs => startMs + word.duration.inMicroseconds / 1000;
  bool get emphasized {
    final int length = word.text.trim().characters.length;
    return word.duration >= const Duration(milliseconds: 1000) &&
        (_cjk.hasMatch(word.text) || (length > 1 && length <= 7));
  }
}

class _LineLayout {
  _LineLayout({
    required this.line,
    required TextStyle style,
    required double width,
    required TextScaler scaler,
    required TextDirection direction,
    required Locale? locale,
  }) {
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
          color: (style.color ?? Colors.black).withValues(alpha: .26),
        ),
      ),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    glow = TextPainter(
      text: TextSpan(
        text: line.text,
        style: style.copyWith(
          color: Colors.transparent,
          shadows: <Shadow>[
            Shadow(
              color: (style.color ?? Colors.white).withValues(alpha: .3),
              blurRadius: math.max(6, (style.fontSize ?? 22) * .32),
            ),
          ],
        ),
      ),
      textDirection: direction,
      textScaler: scaler,
      locale: locale,
    )..layout(maxWidth: width);
    height = bright.height;

    final List<LyricWord> sourceWords = line.words.isNotEmpty
        ? line.words
        : <LyricWord>[
            LyricWord(
              line.time,
              (line.end ?? line.time + const Duration(seconds: 2)) - line.time,
              line.text,
            ),
          ];
    var offset = 0;
    for (var wi = 0; wi < sourceWords.length; wi++) {
      final LyricWord word = sourceWords[wi];
      final _WordRun run = _WordRun(
        word: word,
        index: wi,
        last: wi == sourceWords.length - 1,
      );
      var characterIndex = 0;
      for (final String character in word.text.characters) {
        final int end = offset + character.length;
        for (final TextBox box in bright.getBoxesForSelection(
          TextSelection(baseOffset: offset, extentOffset: end),
        )) {
          final Rect rect = box.toRect();
          if (rect.width <= 0 || rect.height <= 0) continue;
          final double start = run.width;
          run.width += rect.width;
          final _Glyph glyph = _Glyph(
            rect: rect,
            word: run,
            character: characterIndex,
            startFraction: start,
            endFraction: run.width,
          );
          run.glyphs.add(glyph);
          run.path.addRect(rect);
        }
        offset = end;
        characterIndex++;
      }
      if (run.glyphs.isNotEmpty) runs.add(run);
    }
  }

  final LyricLine line;
  late final TextPainter bright;
  late final TextPainter dim;
  late final TextPainter glow;
  late final double height;
  final List<_WordRun> runs = <_WordRun>[];

  int? runAt(double milliseconds) {
    if (runs.isEmpty) return null;
    int low = 0;
    int high = runs.length;
    while (low < high) {
      final int middle = (low + high) ~/ 2;
      if (runs[middle].startMs <= milliseconds) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? null : low - 1;
  }

  void dispose() {
    bright.dispose();
    dim.dispose();
    glow.dispose();
  }
}

class _TimedLinePainter extends CustomPainter {
  _TimedLinePainter({
    required this.layout,
    required this.active,
    required this.position,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final _LineLayout layout;
  final bool active;
  final Duration Function() position;

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) {
      layout.bright.paint(canvas, Offset.zero);
      return;
    }

    final double nowMs = position().inMicroseconds / 1000;
    layout.dim.paint(canvas, Offset.zero);

    final Path settled = Path();
    final List<_WordRun> animating = <_WordRun>[];
    _WordRun? crossing;
    for (final _WordRun run in layout.runs) {
      if (nowMs >= run.endMs) {
        if (nowMs - run.endMs >= 420) {
          settled.addPath(run.path, Offset.zero);
        } else {
          animating.add(run);
        }
      } else if (nowMs >= run.startMs) {
        crossing = run;
        animating.add(run);
        break;
      } else {
        break;
      }
    }
    if (!settled.getBounds().isEmpty) {
      canvas.save();
      canvas.clipPath(settled);
      layout.bright.paint(canvas, Offset.zero);
      canvas.restore();
    }

    if (crossing != null) {
      canvas.save();
      canvas.clipPath(crossing.path);
      layout.glow.paint(canvas, Offset.zero);
      canvas.restore();
    }

    final double fontSize = layout.bright.text?.style?.fontSize ?? 22;
    for (final _WordRun run in animating) {
      final double duration = math.max(1, run.endMs - run.startMs);
      final double elapsed = (nowMs - run.startMs).clamp(0.0, duration);
      final int count = math.max(1, run.characterCount);
      final double totalWidth = math.max(.0001, run.width);
      for (var i = 0; i < run.glyphs.length; i++) {
        final _Glyph glyph = run.glyphs[i];
        final double glyphEndMs =
            run.startMs + duration * (glyph.endFraction / totalWidth);
        final bool isCrossing = identical(run, crossing);
        final bool settling = isCrossing || nowMs - glyphEndMs < 420;
        if (!settling) continue;
        double mask = 1;
        if (isCrossing) {
          final double sungWidth =
              ((elapsed / duration).clamp(0.0, 1.0)) * totalWidth;
          if (sungWidth <= glyph.startFraction) continue;
          mask = ((sungWidth - glyph.startFraction) /
                  math.max(.0001, glyph.endFraction - glyph.startFraction))
              .clamp(0.0, 1.0);
        }
        final LyricWordMotion motion = run.emphasized
            ? LyricWordMotion.emphasized(
                elapsed,
                duration,
                i,
                count,
                last: run.last,
              )
            : LyricWordMotion.ordinary(elapsed, duration);
        final Rect rect = glyph.rect;
        final double dx = motion.xEm * fontSize;
        final double dy = motion.yEm * fontSize;
        canvas.save();
        if (motion.scale != 1 || dx != 0 || dy != 0) {
          canvas.translate(rect.center.dx + dx, rect.center.dy + dy);
          canvas.scale(motion.scale);
          canvas.translate(-rect.center.dx, -rect.center.dy);
        }
        canvas.clipRect(
          Rect.fromLTRB(
            rect.left,
            rect.top - fontSize * .22,
            rect.left + rect.width * mask,
            rect.bottom + fontSize * .22,
          ),
        );
        layout.bright.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TimedLinePainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.active != active ||
      oldDelegate.position != position;
}
