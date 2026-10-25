import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/legacy/legacy_pages.dart';
import 'package:lazer_nextgen/legacy/legacy_shell.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/player/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/ui_preferences.dart';
import 'package:lazer_nextgen/theme/apple_design.dart';

const Track _track = Track(
  id: 'custom-theme-fixture',
  title: 'Fixture',
  artist: 'Test artist',
  album: 'Test album',
  duration: Duration(minutes: 3),
  coverSeed: 2,
);

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
  Future<String?> audioUrlFor(
    Track track, {
    AudioQuality quality = AudioQuality.exhigh,
  }) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async =>
      const GatewayLyrics(lrc: '[00:00.00]First lyric');
  @override
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];
}

Widget _app(Widget home, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: buildLegacyTheme(brightness: brightness),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: home,
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a custom accent persists and seeds the palette', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    expect(state.legacyPalette, LegacyPaletteMode.fixed);
    expect(state.legacyAccentSeed, isNull);

    await state.setLegacyPalette(LegacyPaletteMode.custom);
    expect(
      state.legacyAccentSeed,
      isNull,
      reason: 'the shipped red stays until a colour is chosen',
    );

    await state.setLegacyAccent(const Color(0xFF3366CC));
    expect(state.legacyAccentSeed, const Color(0xFF3366CC));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('lazer_legacy_accent'), 0xFF3366CC);
    expect(prefs.getString('lazer_legacy_palette'), 'custom');

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.legacyPalette, LegacyPaletteMode.custom);
    expect(restarted.legacyAccentSeed, const Color(0xFF3366CC));
    expect(LegacyPaletteModeLabels.parse('custom'), LegacyPaletteMode.custom);
    expect(LegacyPaletteModeLabels.parse('nope'), LegacyPaletteMode.fixed);
  });

  test('a custom picture is its own persistent background mode', () async {
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackgroundImage('/tmp/backdrop.png');
    await state.setLegacyBackground(LegacyBackgroundMode.customImage);
    expect(state.legacyBackgroundImagePath, '/tmp/backdrop.png');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('lazer_legacy_background_image'),
      '/tmp/backdrop.png',
    );
    expect(prefs.getString('lazer_legacy_background'), 'customImage');

    final AppState restarted = AppState(catalog: _Catalog());
    addTearDown(restarted.dispose);
    await restarted.bootstrap();
    expect(restarted.legacyBackgroundImagePath, '/tmp/backdrop.png');
    expect(restarted.legacyBackground, LegacyBackgroundMode.customImage);

    await restarted.setLegacyBackgroundImage(null);
    expect(prefs.getString('lazer_legacy_background_image'), isNull);
    expect(restarted.legacyBackgroundImagePath, isNull);
  });

  testWidgets('an off dark backdrop is a lifted canvas, never pure black', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackground(LegacyBackgroundMode.off);

    await tester.pumpWidget(_app(LegacyShell(state: state)));
    await tester.pumpAndSettle();
    final Scaffold scaffold = tester.widget<Scaffold>(
      find.byType(Scaffold).first,
    );
    expect(scaffold.backgroundColor, AppleColors.darkCanvas);
    expect(scaffold.backgroundColor, isNot(Colors.black));
    expect(find.byType(LegacyAlbumBackdrop), findsNothing);

    // The light theme keeps the system background, which is already not black.
    await tester.pumpWidget(
      _app(LegacyShell(state: state), brightness: Brightness.light),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor,
      AppleSemanticColors.light.background,
    );
  });

  testWidgets('a custom picture paints behind the shell content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory directory = Directory.systemTemp.createTempSync(
      'lazer-backdrop',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final File image = File('${directory.path}${Platform.pathSeparator}bg.png')
      ..writeAsBytesSync(_onePixelPng);

    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackgroundImage(image.path);
    await state.setLegacyBackground(LegacyBackgroundMode.customImage);

    await tester.pumpWidget(_app(LegacyShell(state: state)));
    await tester.pump();
    expect(find.byType(LegacyAlbumBackdrop), findsOneWidget);
    expect(find.byType(AlbumFlowBackground), findsNothing);
    final Image painted = tester.widget<Image>(find.byType(Image).first);
    expect(painted.image, isA<FileImage>());
    expect((painted.image as FileImage).file.path, image.path);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the player keeps its album flow when the backdrop is off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyBackground(LegacyBackgroundMode.off);
    state.playQueue(const <Track>[_track]);

    await tester.pumpWidget(_app(LegacyShell(state: state)));
    await tester.pump();
    await tester.tap(find.byTooltip('歌词'));
    await tester.pumpAndSettle();
    expect(find.byType(NowPlayingPage), findsOneWidget);
    final Finder flow = find.byType(AlbumFlowBackground);
    expect(flow, findsOneWidget);
    expect(
      find.ancestor(of: flow, matching: find.byType(NowPlayingPage)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings expose the accent swatch and the picture row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) =>
              Scaffold(body: LegacySettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('强调色'), findsNothing);

    await state.setLegacyPalette(LegacyPaletteMode.custom);
    await tester.pumpAndSettle();
    expect(find.text('强调色'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('legacy-accent-swatch')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(state.legacyAccentColor, AppleColors.musicRed);
    expect(find.text('#FA2D48'), findsOneWidget);

    await state.setLegacyBackground(LegacyBackgroundMode.customImage);
    await tester.pumpAndSettle();
    expect(find.text('背景图片'), findsOneWidget);
    expect(find.byKey(const ValueKey('background-image-pick')), findsOneWidget);
    expect(find.byKey(const ValueKey('background-image-clear')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the accent picker fits a phone-width settings page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await state.setLegacyPalette(LegacyPaletteMode.custom);

    await tester.pumpWidget(
      _app(
        AnimatedBuilder(
          animation: state,
          builder: (BuildContext context, _) =>
              Scaffold(body: LegacySettingsPage(state: state)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('legacy-accent-swatch')));
    await tester.pumpAndSettle();
    expect(find.text('自定义主题色'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state.legacyAccentColor, isNull);
  });
}

/// 1×1 transparent PNG; enough for [Image.file] to resolve without errors.
const List<int> _onePixelPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
