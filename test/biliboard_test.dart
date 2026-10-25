import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lazer_nextgen/data/biliboard.dart';
import 'package:lazer_nextgen/data/models.dart';

void main() {
  test('Biliboard public feed becomes a chart with source metadata', () async {
    final client = MockClient((http.Request request) async {
      final path = request.url.path;
      if (path == '/api/public/boards') {
        return http.Response(
          '[{"id":1,"name":"周榜"}]',
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (path == '/api/public/boards/1/issues') {
        return http.Response(
          '[{"id":226,"issue_id":124,"year":2026,"week":43},'
          '{"id":225,"issue_id":123,"year":2026,"week":42}]',
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (path == '/api/public/boards/1/issues/124/rankings') {
        return http.Response(
          '[{"rank":1,"title":"Song","titleCn":"歌曲",'
          '"producers":[{"name":"Producer"}],'
          '"vocalists":[{"name":"Vocal"}],"bvid":"BV123",'
          '"coverUrl":"/cover.jpg","lastRank":2,"peakRank":1,'
          '"weeksOnBoard":3,"score":9876,'
          '"rateHistory":[{"value":3.2},{"value":4.5}],'
          '"rankChange":{"kind":"up","diff":1}}]',
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      return http.Response('not found', 404);
    });

    final charts = await BiliboardClient(client: client).latestCharts();

    expect(charts, hasLength(1));
    expect(charts.single.title, '周榜');
    expect(charts.single.issueLabel, '2026 · 第 43 周');
    expect(charts.single.issues, hasLength(2));
    expect(charts.single.selectedIssueId, 124);
    expect(charts.single.entries.single.artist, 'Producer');
    expect(charts.single.entries.single.score, 9876);
    expect(charts.single.entries.single.trend, <double>[3.2, 4.5]);
    expect(charts.single.entries.single.changeLabel, '↑1');
    expect(
      charts.single.entries.single.coverUrl,
      'https://biliboard.uk/cover.jpg',
    );
    expect(
      charts.single.entries.single.sourceUrl,
      'https://www.bilibili.com/video/BV123',
    );
  });

  test('loads a selected historical issue', () async {
    final client = MockClient((http.Request request) async {
      if (request.url.path == '/api/public/boards/1/issues/123/rankings') {
        return http.Response(
          '[{"rank":2,"title":"Older","producers":[],"vocalists":[]}]',
          200,
        );
      }
      return http.Response('not found', 404);
    });
    final api = BiliboardClient(client: client);
    const issue = ChartIssue(id: 123, label: '2026 · 第 42 周');
    const chart = MusicChart(
      id: 'biliboard:1:124',
      title: '周榜',
      source: 'Biliboard',
      issueLabel: '2026 · 第 43 周',
      entries: <ChartEntry>[],
      providerKey: 'biliboard:1',
      issues: <ChartIssue>[issue],
      selectedIssueId: 124,
    );

    final result = await api.chartForIssue(chart, issue);

    expect(result.selectedIssueId, 123);
    expect(result.issueLabel, issue.label);
    expect(result.entries.single.title, 'Older');
  });

  test(
    'prefers the static weekly archive for reliable issue switching',
    () async {
      final requestedHosts = <String>[];
      final client = MockClient((http.Request request) async {
        requestedHosts.add(request.url.host);
        if (request.url.path.endsWith('/data/bilibili/index.json')) {
          return http.Response(
            '{"issues":[{"issue":123,"path":"weekly/issue_123.json"}]}',
            200,
          );
        }
        if (request.url.path.endsWith('/weekly/issue_123.json')) {
          return http.Response(
            '{"items":[{"rank":1,"title":"敌人",'
            '"bvid":"BV1UGa961Ejt",'
            '"pic_url":"http://image.example/cover.jpg",'
            '"url":"https://www.bilibili.com/video/BV1"}]}',
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }
        return http.Response('not found', 404);
      });
      final api = BiliboardClient(client: client);
      const issue = ChartIssue(id: 123, label: '2026 · 第 42 周');
      const chart = MusicChart(
        id: 'biliboard:1:124',
        title: '周榜',
        source: 'Biliboard',
        issueLabel: '2026 · 第 43 周',
        entries: <ChartEntry>[],
        providerKey: 'biliboard:1',
        issues: <ChartIssue>[issue],
        selectedIssueId: 124,
      );

      final result = await api.chartForIssue(chart, issue);

      expect(result.entries.single.title, 'えねみぃ');
      expect(result.entries.single.translatedTitle, '敌人');
      expect(result.entries.single.artist, 'ピノキオピー');
      expect(result.entries.single.coverUrl, 'https://image.example/cover.jpg');
      expect(requestedHosts, everyElement('cdn.jsdelivr.net'));
    },
  );
}
