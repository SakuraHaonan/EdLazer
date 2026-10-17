import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_now_playing.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'パベル',
  artist: 'いよわ / 重音テト',
  album: 'パベル',
  duration: Duration(minutes: 2, seconds: 26),
  coverSeed: 3,
  translatedTitle: '巴别塔',
);

const String _lrc =
    '[00:00.00]拙いペースを守る 守る\n'
    '[00:06.00]いつの間に建った\n'
    '[00:12.00]未開の塔で答えを考え中\n'
    '[00:18.00]カルチャーを文字で話す 話す';

const String _tlyric =
    '[00:00.00]谨慎地遵守着步调\n'
    '[00:06.00]在不知不觉间建成的\n'
    '[00:12.00]在未开拓的高塔上思考着答案\n'
    '[00:18.00]用文字讲述文化';

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[],
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[],
    albums: <Album>[],
  );
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: _lrc, tlyric: _tlyric);
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: home,
);

Future<AppState> _playing(WidgetTester tester) async {
  final AppState state = AppState(catalog: _Catalog());
  addTearDown(state.dispose);
  state.playQueue(const <Track>[_track]);
  await tester.pump(const Duration(milliseconds: 50));
  return state;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the legacy lyric size starts at the Lazer default and persists', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.legacyLyricFontSize, 34);
    await state.setLegacyLyricFontSize(41);
    expect(state.legacyLyricFontSize, 42, reason: 'snaps to the 2 sp ladder');
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'lazer_legacy_lyric_font_size',
      ),
      42,
    );
    await state.setLegacyLyricFontSize(10);
    expect(state.legacyLyricFontSize, 22);

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.legacyLyricFontSize, 22);
  });

  testWidgets('the legacy player bar fits its 84 dp rule', (tester) async {
    for (final Size size in <Size>[
      const Size(1440, 900),
      const Size(1100, 760),
      const Size(900, 700),
      const Size(520, 900),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final AppState state = await _playing(tester);
      await tester.pumpWidget(_app(LegacyShell(state: state)));
      await tester.pump(const Duration(milliseconds: 120));
      expect(find.byType(LegacyPlayerBar), findsOneWidget);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the transport bar overflowed at $size',
      );
    }
    addTearDown(tester.view.reset);
  });

  testWidgets('the legacy now playing page shows lyrics and seeks on tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = await _playing(tester);
    await tester.pumpWidget(_app(LegacyNowPlayingPage(state: state)));
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('パベル'), findsWidgets);
    expect(find.text('巴别塔'), findsOneWidget);
    expect(find.text('拙いペースを守る 守る'), findsOneWidget);
    expect(find.text('谨慎地遵守着步调'), findsOneWidget);
    expect(find.byType(LegacyThinSeekBar), findsWidgets);
    expect(tester.takeException(), isNull);

    // The third line sits at 12 s; tapping it seeks the transport there.
    await tester.tap(find.text('未開の塔で答えを考え中'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(state.precisePosition.inSeconds, greaterThanOrEqualTo(12));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the legacy now playing page folds onto a narrow window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(520, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = await _playing(tester);
    await tester.pumpWidget(_app(LegacyNowPlayingPage(state: state)));
    await tester.pump(const Duration(milliseconds: 120));
    expect(tester.takeException(), isNull);
  });
}
