import 'lyric_document.dart';

/// A stable key survives line list rebuilds and keeps a selection anchored to
/// the exact timestamp + text pair.
String? lyricSelectionKey(LyricLine line) {
  final String text = line.text.trim();
  return text.isEmpty ? null : '${line.time.inMilliseconds}\u0000$text';
}

/// Immutable lyric selection model.
class LyricSelection {
  const LyricSelection({this.anchor, this.keys = const <String>{}});

  final String? anchor;
  final Set<String> keys;

  bool get active => anchor != null;
  int get count => keys.length;
  bool contains(LyricLine line) => keys.contains(lyricSelectionKey(line));

  LyricSelection begin(List<LyricLine> lines, int index) {
    if (index < 0 || index >= lines.length) return this;
    final String? key = lyricSelectionKey(lines[index]);
    return key == null
        ? this
        : LyricSelection(anchor: key, keys: <String>{key});
  }

  LyricSelection toggle(List<LyricLine> lines, int index) {
    if (!active) return begin(lines, index);
    if (index < 0 || index >= lines.length) return this;
    final String? key = lyricSelectionKey(lines[index]);
    if (key == null) return this;
    final Set<String> next = <String>{...keys};
    if (!next.add(key)) next.remove(key);
    if (next.isEmpty) return const LyricSelection();
    String? nextAnchor = anchor;
    if (nextAnchor == key) {
      final List<int> alive = <int>[
        for (int i = 0; i < lines.length; i++)
          if (next.contains(lyricSelectionKey(lines[i]))) i,
      ]..sort((a, b) => (a - index).abs().compareTo((b - index).abs()));
      nextAnchor = lyricSelectionKey(lines[alive.first]);
    }
    return LyricSelection(anchor: nextAnchor, keys: next);
  }

  LyricSelection extend(List<LyricLine> lines, int index) {
    if (index < 0 || index >= lines.length) return this;
    if (!active) return begin(lines, index);
    final int from = lines.indexWhere(
      (LyricLine line) => lyricSelectionKey(line) == anchor,
    );
    if (from < 0) return begin(lines, index);
    final int first = from < index ? from : index;
    final int last = from > index ? from : index;
    return LyricSelection(
      anchor: anchor,
      keys: <String>{
        for (int i = first; i <= last; i++) ?lyricSelectionKey(lines[i]),
      },
    );
  }

  LyricSelection all(List<LyricLine> lines) {
    final Set<String> every = <String>{
      for (final LyricLine line in lines) ?lyricSelectionKey(line),
    };
    if (every.isEmpty) return this;
    return LyricSelection(
      anchor: anchor != null && every.contains(anchor) ? anchor : every.first,
      keys: every,
    );
  }

  String text(List<LyricLine> lines) {
    final StringBuffer buffer = StringBuffer();
    for (final LyricLine line in lines) {
      if (!keys.contains(lyricSelectionKey(line))) continue;
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(line.text.trim());
      final String? translation = line.translation?.trim();
      if (translation != null && translation.isNotEmpty) {
        buffer
          ..write('\n')
          ..write(translation);
      }
    }
    return buffer.toString();
  }
}
