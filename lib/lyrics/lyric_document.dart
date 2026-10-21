import '../gateway/gateway.dart';

/// One timed word inside an enhanced (YRC) lyric line.
class LyricWord {
  const LyricWord(this.start, this.duration, this.text);

  final Duration start;
  final Duration duration;
  final String text;
}

/// One lyric line. Enhanced lines carry [words] and an [end] boundary; plain
/// LRC lines leave those empty and are advanced by their timestamps alone.
class LyricLine {
  const LyricLine(
    this.time,
    this.text, {
    this.translation,
    this.words = const <LyricWord>[],
    this.end,
  });

  final Duration time;
  final String text;
  final String? translation;
  final List<LyricWord> words;
  final Duration? end;
}

final RegExp _stamp = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final RegExp _yrcLine = RegExp(r'^\[(\d+),(\d+)\](.*)$');
final RegExp _yrcWord = RegExp(
  r'\((\d+),(\d+),(-?\d+)\)(.*?)(?=\(\d+,\d+,-?\d+\)|$)',
);

Duration _lrcStamp(RegExpMatch match) {
  final String fraction = (match.group(3) ?? '').padRight(3, '0');
  return Duration(
    minutes: int.parse(match.group(1)!),
    seconds: int.parse(match.group(2)!),
    milliseconds: fraction.isEmpty ? 0 : int.parse(fraction),
  );
}

/// The standard LRC reader. Multiple timestamps on one row expand into
/// separate lines, JSON-only credit rows are ignored, and timestamps accept
/// both decimal points and the less common colon fraction.
List<LyricLine> parseLrc(String? source) {
  final String raw = source?.trim() ?? '';
  if (raw.isEmpty) return const <LyricLine>[];
  final List<LyricLine> result = <LyricLine>[];
  for (final String row in raw.split(RegExp(r'\r?\n'))) {
    final List<RegExpMatch> marks = _stamp.allMatches(row).toList();
    if (marks.isEmpty) continue;
    final String body = row.substring(marks.last.end).trim();
    for (final RegExpMatch mark in marks) {
      result.add(LyricLine(_lrcStamp(mark), body));
    }
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// The enhanced YRC reader. Every word offset is an absolute song position,
/// which lets the renderer sweep a line without accumulating parse drift.
List<LyricLine> parseYrc(String? source) {
  final String raw = source?.trim() ?? '';
  if (raw.isEmpty) return const <LyricLine>[];
  final List<LyricLine> result = <LyricLine>[];
  for (final String row in raw.split(RegExp(r'\r?\n'))) {
    final RegExpMatch? lineMatch = _yrcLine.firstMatch(row.trim());
    if (lineMatch == null) continue;
    final int lineStart = int.parse(lineMatch.group(1)!);
    final int lineDuration = int.parse(lineMatch.group(2)!);
    final List<LyricWord> words = <LyricWord>[];
    for (final RegExpMatch wordMatch in _yrcWord.allMatches(lineMatch.group(3)!)) {
      final String wordText = wordMatch.group(4)!;
      if (wordText.isEmpty) continue;
      words.add(
        LyricWord(
          Duration(milliseconds: int.parse(wordMatch.group(1)!)),
          Duration(
            milliseconds: int.parse(wordMatch.group(2)!).clamp(1, 1 << 62),
          ),
          wordText,
        ),
      );
    }
    if (words.isEmpty) continue;
    result.add(
      LyricLine(
        Duration(milliseconds: lineStart),
        words.map((LyricWord word) => word.text).join(),
        words: words,
        end: Duration(milliseconds: lineStart + lineDuration),
      ),
    );
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

/// Merge original lyrics with the best available translation source.
///
/// A translation is attached only when its timestamp lands within one second
/// of the source line. Searching the complete translation list avoids the old
/// forward-only failure where equal-time credit rows blocked later matches.
List<LyricLine> parseLyrics(GatewayLyrics payload) {
  final List<LyricLine> enhanced = parseYrc(payload.yrc);
  final List<LyricLine> source = enhanced.isNotEmpty
      ? enhanced
      : parseLrc(payload.lrc);
  final List<LyricLine> translated = parseLrc(payload.tlyric).isNotEmpty
      ? parseLrc(payload.tlyric)
      : parseLrc(payload.ytlrc);
  if (source.isEmpty || translated.isEmpty) return source;
  return <LyricLine>[
    for (final LyricLine line in source)
      _withTranslation(line, translated),
  ];
}

LyricLine _withTranslation(LyricLine line, List<LyricLine> translated) {
  LyricLine? nearest;
  int distance = 1 << 62;
  for (final LyricLine candidate in translated) {
    final int current = (candidate.time - line.time).inMilliseconds.abs();
    if (current < distance) {
      distance = current;
      nearest = candidate;
    }
  }
  final String? text = nearest?.text.trim();
  return LyricLine(
    line.time,
    line.text,
    words: line.words,
    end: line.end,
    translation: distance <= 1000 && text != null && text.isNotEmpty && text != line.text
        ? text
        : null,
  );
}
