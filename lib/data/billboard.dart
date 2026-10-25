import 'package:http/http.dart' as http;

import 'models.dart';

/// Reads the public Billboard Hot 100 page so the chart keeps all 100 rows,
/// artwork and published movement metadata instead of inheriting the shorter
/// NetEase mirror.
class BillboardClient {
  BillboardClient({http.Client? client}) : _client = client ?? http.Client();

  static final Uri _hot100 = Uri.parse(
    'https://www.billboard.com/charts/hot-100/',
  );
  final http.Client _client;

  Future<MusicChart?> latestChart() async {
    final response = await _client
        .get(
          _hot100,
          headers: const <String, String>{
            'accept': 'text/html,application/xhtml+xml',
            'user-agent': 'Mozilla/5.0 Lazer/1.0',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('Billboard request failed: ${response.statusCode}');
    }

    final html = response.body;
    final entries = <ChartEntry>[];
    for (final segment
        in html.split('o-chart-results-list-row-container').skip(1)) {
      final rank = int.tryParse(_capture(segment, _rankPattern) ?? '');
      final title = _clean(_capture(segment, _titlePattern) ?? '');
      if (rank == null || title.isEmpty) continue;
      final cover = _decodeEntities(_capture(segment, _coverPattern) ?? '');
      final previousText = _capture(segment, _lastWeekPattern);
      final previousRank = int.tryParse(previousText ?? '');
      final changeLabel = previousText == '-'
          ? 'NEW'
          : previousRank == null
          ? null
          : previousRank > rank
          ? '↑${previousRank - rank}'
          : previousRank < rank
          ? '↓${rank - previousRank}'
          : '—';
      entries.add(
        ChartEntry(
          rank: rank,
          title: title,
          artist: _clean(_stripTags(_capture(segment, _artistPattern) ?? '')),
          coverUrl: cover.isEmpty ? null : cover,
          previousRank: previousRank,
          peakRank: int.tryParse(_capture(segment, _peakPattern) ?? ''),
          weeksOnChart: int.tryParse(_capture(segment, _weeksPattern) ?? ''),
          changeLabel: changeLabel,
        ),
      );
      if (entries.length == 100) break;
    }
    if (entries.isEmpty) return null;
    final issue = _clean(
      _capture(html, _issuePattern) ?? 'Current chart',
    ).replaceFirst(RegExp(r'^Week of\s+', caseSensitive: false), '');
    return MusicChart(
      id: 'billboard:hot-100:$issue',
      title: '美国 Billboard Hot 100',
      source: 'Billboard',
      issueLabel: issue,
      entries: entries,
      accent: 0xFFE7384F,
      providerKey: 'billboard:hot-100',
    );
  }

  static final RegExp _rankPattern = RegExp(
    r'<span class="c-label[^>]*>\s*(\d+)\s*</span>',
    multiLine: true,
  );
  static final RegExp _titlePattern = RegExp(
    r'<h3[^>]*>\s*([^<]+?)\s*</h3>',
    multiLine: true,
  );
  static final RegExp _artistPattern = RegExp(
    r'<span class="[^"]*a-no-trucate[^"]*"[^>]*>([\s\S]*?)</span>',
  );
  static final RegExp _coverPattern = RegExp(r'<img[^>]+src="([^"]+)"');
  static final RegExp _lastWeekPattern = _metricPattern('LW');
  static final RegExp _peakPattern = _metricPattern('PEAK');
  static final RegExp _weeksPattern = _metricPattern('WEEKS ON CHART');
  static final RegExp _issuePattern = RegExp(
    r'(Week of\s+[A-Z][a-z]+\s+\d{1,2},\s+\d{4})',
  );

  static RegExp _metricPattern(String label) => RegExp(
    '>\\s*${RegExp.escape(label)}\\s*</span>[\\s\\S]{0,1800}?'
    r'<span class="c-label[^>]*>\s*([\d-]+)',
  );

  static String? _capture(String input, RegExp pattern) {
    final match = pattern.firstMatch(input);
    return match == null || match.groupCount < 1 ? null : match.group(1);
  }

  static String _stripTags(String value) =>
      value.replaceAll(RegExp(r'<[^>]+>'), '');

  static String _clean(String value) =>
      _decodeEntities(value).replaceAll(RegExp(r'\s+'), ' ').trim();

  static String _decodeEntities(String value) => value
      .replaceAll('&#039;', "'")
      .replaceAll('&#8217;', '’')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&nbsp;', ' ');
}
