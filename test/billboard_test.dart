import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lazer_nextgen/data/billboard.dart';

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
  });
}
