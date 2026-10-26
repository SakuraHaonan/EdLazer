import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';

const Track _track = Track(
  id: 'open-cost',
  title: 'Open cost fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

const Playlist _playlist = Playlist(
  id: '1',
  name: 'Open cost playlist',
  trackIds: <String>[],
  coverSeed: 1,
  trackCount: 1,
);

class _Catalog extends Catalog {
  @override
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric\n[00:05.00]Second lyric');
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: <Playlist>[_playlist],
    featured: Album(
      id: '9',
      title: 'Fixture album',
      artist: 'Test artist',
      year: '2024',
      coverSeed: 1,
      note: '',
    ),
    featuredTracks: <Track>[_track],
    quick: <Track>[_track],
    playlists: <Playlist>[_playlist],
    albums: <Album>[],
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('opening the player rebuilds nothing but the player itself', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    state.playQueue(const <Track>[_track]);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: LegacyShell(state: state),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    int playerBuilds = 0;
    int browseBuilds = 0;
    debugOnRebuildDirtyWidget = (Element element, bool builtOnce) {
      final Type type = element.widget.runtimeType;
      if (type == NowPlayingPage) playerBuilds++;
      if (type == LegacyHomePage) browseBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);

    await tester.tap(
      find.descendant(
        of: find.byType(LegacyPlayerBar),
        matching: find.text(_track.title),
      ),
    );
    await tester.pump();
    expect(playerBuilds, 1, reason: 'the player is built once, on its frame');
    expect(
      browseBuilds,
      0,
      reason: 'the page the player is about to cover is not rebuilt',
    );

    // The 300 ms entrance runs, and lands.
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(
      playerBuilds,
      1,
      reason: 'the entrance landing must not rebuild the whole player',
    );
    expect(browseBuilds, 0);
    expect(tester.takeException(), isNull);
  });
}
