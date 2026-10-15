import '../gateway/gateway.dart';

class LyricWord {
  const LyricWord(this.start, this.duration, this.text);
  final Duration start;
  final Duration duration;
  final String text;
}

class LyricLine {
  const LyricLine(
    this.time,
    this.text, {
    this.translation,
    this.words = const [],
    this.end,
  });
  final Duration time;
  final String text;
  final String? translation;
  final List<LyricWord> words;
  final Duration? end;
}

/// Port of LrcRow.kt and LyricTimeline.kt: both fractional separators and
/// multiple timestamps are supported; untimed JSON credits are ignored.
List<LyricLine> parseLrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final stamp = RegExp(r'\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]');
  final lines = <LyricLine>[];
  for (final row in source.split(RegExp(r'[\r\n]+'))) {
    final matches = stamp.allMatches(row).toList();
    if (matches.isEmpty) continue;
    final text = row.substring(matches.last.end).trim();
    for (final match in matches) {
      final fraction = (match.group(3) ?? '').padRight(3, '0');
      lines.add(
        LyricLine(
          Duration(
            minutes: int.parse(match.group(1)!),
            seconds: int.parse(match.group(2)!),
            milliseconds: int.parse(fraction),
          ),
          text,
        ),
      );
    }
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

/// Port of WordLyrics.kt; word offsets are absolute song positions.
List<LyricLine> parseYrc(String? source) {
  if (source == null || source.trim().isEmpty) return const [];
  final linePattern = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  final wordPattern = RegExp(
    r'\((\d+),(\d+),(\d+)\)(.*?)(?=\(\d+,\d+,\d+\)|$)',
  );
  final lines = <LyricLine>[];
  for (final raw in source.split(RegExp(r'[\r\n]+'))) {
    final line = linePattern.firstMatch(raw.trim());
    if (line == null) continue;
    final words = <LyricWord>[
      for (final word in wordPattern.allMatches(line.group(3)!))
        if (word.group(4)!.isNotEmpty)
          LyricWord(
            Duration(milliseconds: int.parse(word.group(1)!)),
            Duration(milliseconds: int.parse(word.group(2)!).clamp(1, 1 << 62)),
            word.group(4)!,
          ),
    ];
    if (words.isEmpty) continue;
    final time = Duration(milliseconds: int.parse(line.group(1)!));
    lines.add(
      LyricLine(
        time,
        words.map((word) => word.text).join(),
        words: words,
        end: time + Duration(milliseconds: int.parse(line.group(2)!)),
      ),
    );
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return lines;
}

List<LyricLine> parseLyrics(GatewayLyrics payload) {
  final words = parseYrc(payload.yrc);
  final original = words.isNotEmpty ? words : parseLrc(payload.lrc);
  final regularTranslations = parseLrc(payload.tlyric);
  final translations = regularTranslations.isNotEmpty
      ? regularTranslations
      : parseLrc(payload.ytlrc);
  if (translations.isEmpty) return original;
  return original.map((line) {
    int delta(int index) =>
        (translations[index].time - line.time).inMilliseconds.abs();
    // Find the insertion point; equal-time credits must not block all later
    // translations by making a forward-only nearest search stop at a tie.
    int low = 0;
    int high = translations.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (translations[middle].time < line.time) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    int cursor = (low - 1).clamp(0, translations.length - 1);
    if (low < translations.length && delta(low) < delta(cursor)) cursor = low;
    final text = delta(cursor) <= 1000 ? translations[cursor].text.trim() : '';
    return LyricLine(
      line.time,
      line.text,
      words: line.words,
      end: line.end,
      translation: text.isEmpty || text == line.text ? null : text,
    );
  }).toList();
}
