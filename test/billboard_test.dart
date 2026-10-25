import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lazer_nextgen/data/billboard.dart';
import 'package:lazer_nextgen/data/models.dart';

void main() {
  test('keeps all 100 Hot 100 rows and movement metadata', () async {
    final rows = List<String>.generate(100, (index) {
      final rank = index + 1;
      final previous = rank == 100 ? '-' : '${rank + 1}';
      return '''
        <div class="o-chart-results-list-row-container">
          <span class="c-label">$rank</span>
          <img src="https://example.com/$rank.jpg">
          <h3>Song $rank</h3>
          <span class="c-label a-no-trucate"><a>Artist $rank</a></span>
          <span>LW</span><span class="c-label">$previous</span>
          <span>PEAK</span><span class="c-label">1</span>
          <span>WEEKS ON CHART</span><span class="c-label">8</span>
        </div>
      ''';
    }).join();
    final client = MockClient(
      (_) async => http.Response('<p>Week of October 24, 2026</p>$rows', 200),
    );

    final chart = await BillboardClient(client: client).latestChart();

    expect(chart, isNotNull);
    expect(chart!.entries, hasLength(100));
    expect(
      chart.entries.first.changeLabel,
      '↑'
      '1',
    );
    expect(chart.entries.last.changeLabel, 'NEW');
    expect(chart.entries.first.coverUrl, 'https://example.com/1.jpg');
    expect(chart.issueLabel, 'October 24, 2026');
    expect(chart.issues, hasLength(52));
    expect(chart.selectedIssueId, 20261024);
    expect(chart.entries.first.trend, <double>[99, 100]);
  });

  test('loads a selected historical Hot 100 issue by date', () async {
    Uri? requested;
    final client = MockClient((request) async {
      requested = request.url;
      return http.Response('''
        <p>Week of October 17, 2026</p>
        <div class="o-chart-results-list-row-container">
          <span class="c-label">1</span>
          <img src="https://example.com/1.jpg">
          <h3>Song 1</h3>
          <span class="c-label a-no-trucate"><a>Artist 1</a></span>
          <span>LW</span><span class="c-label">3</span>
          <span>PEAK</span><span class="c-label">1</span>
          <span>WEEKS ON CHART</span><span class="c-label">9</span>
        </div>
      ''', 200);
    });
    const issues = <ChartIssue>[
      ChartIssue(id: 20261024, label: '2026 · 10月24日'),
      ChartIssue(id: 20261017, label: '2026 · 10月17日'),
    ];
    const chart = MusicChart(
      id: 'billboard:hot-100:October 24, 2026',
      title: '美国 Billboard Hot 100',
      source: 'Billboard',
      issueLabel: 'October 24, 2026',
      entries: <ChartEntry>[],
      providerKey: 'billboard:hot-100',
      issues: issues,
      selectedIssueId: 20261024,
    );

    final loaded = await BillboardClient(
      client: client,
    ).chartForIssue(chart, issues.last);

    expect(requested?.path, '/charts/hot-100/2026-10-17/');
    expect(loaded.entries, hasLength(1));
    expect(loaded.issues, issues);
    expect(loaded.selectedIssueId, 20261017);
  });

  test(
    'builds the complete current chart run from prior weekly issues',
    () async {
      final client = MockClient((request) async {
        final date = request.url.pathSegments.lastWhere(
          (part) => part.endsWith('.json'),
        );
        final ranks = <String, int>{'2026-10-17.json': 2, '2026-10-10.json': 4};
        final rank = ranks[date];
        return http.Response(
          jsonEncode(<String, Object?>{
            'date': date.substring(0, 10),
            'data': rank == null
                ? const <Object>[]
                : <Object>[
                    <String, Object?>{
                      'song': 'Patient Zero',
                      'artist': 'Taylor Swift',
                      'this_week': rank,
                    },
                  ],
          }),
          200,
        );
      });
      const chart = MusicChart(
        id: 'billboard:hot-100:October 24, 2026',
        title: '美国 Billboard Hot 100',
        source: 'Billboard',
        issueLabel: 'October 24, 2026',
        providerKey: 'billboard:hot-100',
        selectedIssueId: 20261024,
        entries: <ChartEntry>[
          ChartEntry(
            rank: 1,
            title: 'Patient Zero',
            artist: 'Taylor Swift',
            weeksOnChart: 3,
            trend: <double>[99, 100],
          ),
        ],
      );

      final enriched = await BillboardClient(client: client).withHistory(chart);

      expect(enriched.entries.single.trend, <double>[97, 99, 100]);
    },
  );
}
