import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/audio/audio_engine.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_background.dart';
import 'package:lazer_nextgen/legacy/legacy_now_playing.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  translatedTitle: '测试译名',
);

const Track _coverTrack = Track(
  id: '1939575648',
  title: 'Cover fixture',
  artist: 'Test',
  album: 'Album',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  coverUrl:
      'https://p1.music.126.net/abcdef/109951173819308049.jpg?param=1024y1024',
);

class _Gateway extends NeteaseGateway {
  @override
  Future<Set<int>> likedSongIds(int uid) async => <int>{};

  @override
  Future<Map<String, dynamic>> songComments(
    int songId, {
    int limit = 20,
    int offset = 0,
  }) async => <String, dynamic>{
    'total': 1,
    'more': false,
    'hotComments': <dynamic>[],
    'comments': <dynamic>[
      <String, dynamic>{
        'commentId': 1,
        'content': '桌面评论',
        'time': 0,
        'likedCount': 2,
        'user': <String, dynamic>{'nickname': '听者', 'userId': 9},
      },
    ],
  };

  @override
  Future<void> setSongCommentLiked(
    int songId,
    int commentId,
    bool liked,
  ) async {}
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
  Future<String?> audioUrlFor(Track track) async =>
      'https://example.com/song.mp3';

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]第一句歌词\n[00:08.00]第二句歌词\n[00:16.00]第三句歌词',
    tlyric: '[00:00.00]第一句翻译\n[00:08.00]第二句翻译\n[00:16.00]第三句翻译',
  );
}

/// Keeps the transport "playing" without touching a real audio backend.
class _FakeEngine implements AudioEngine {
  bool _active = false;
  Duration _position = Duration.zero;
  double volume = 1;

  @override
  bool get active => _active;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _track.duration;

  @override
  Stream<void> get completed => const Stream<void>.empty();

  @override
  Future<void> setUrl(String url) async => _active = true;

  @override
  Future<void> play() async => _active = true;

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async => _position = position;

  @override
  Future<void> setVolume(double value) async => volume = value;

  @override
  Future<void> stop() async => _active = false;

  @override
  void dispose() {}
}

AppState _state({bool playing = false}) {
  final AppState state = AppState(
    catalog: playing ? _Catalog() : _SilentCatalog(),
    audioEngine: playing ? _FakeEngine() : null,
  );
  state.playQueue(<Track>[_track]);
  return state;
}

/// A catalogue that cannot start playback (no stream URL), leaving the page
/// mounted without a live transport ticker.
class _SilentCatalog extends _Catalog {
  @override
  Future<String?> audioUrlFor(Track track) async => null;
}

Widget _app(AppState state, {GlobalKey? key}) => RepaintBoundary(
  key: key,
  child: MaterialApp(
    theme: buildLegacyTheme(brightness: Brightness.dark),
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: child!,
    ),
    home: LegacyNowPlayingPage(state: state),
  ),
);

Future<void> _snapshot(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image image = await boundary.toImage(pixelRatio: 1);
    final ByteData? bytes = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await Directory('diag').create(recursive: true);
    await File('diag/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final FontLoader font = FontLoader('MiSans')
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'));
    await font.load();
    final FontLoader icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('desktop now playing fits every desktop window', (tester) async {
    addTearDown(tester.view.reset);
    for (final Size size in <Size>[
      const Size(1100, 760),
      const Size(1280, 800),
      const Size(1440, 900),
      const Size(1920, 1080),
    ]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      final AppState state = _state();
      addTearDown(state.dispose);
      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('desktop-now-playing')),
        findsOneWidget,
        reason: 'desktop page missing at $size',
      );
      expect(find.byType(LyricViewport), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('desktop-seek-bar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull, reason: 'overflow at $size');
    }
  });

  testWidgets(
    'desktop now playing uses the Apple Music theme and the shell album flow',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue(<Track>[_coverTrack]);
      await tester.pumpWidget(_app(state));
      await tester.pumpAndSettle();

      final ThemeData page = Theme.of(
        tester.element(find.byKey(const ValueKey<String>('desktop-seek-bar'))),
      );
      expect(page.brightness, Brightness.dark);
      expect(page.colorScheme.primary, Colors.white);
      expect(page.colorScheme.secondary, const Color(0xFFFA2D48));

      final LyricViewport lyrics = tester.widget<LyricViewport>(
        find.byType(LyricViewport),
      );
      expect(lyrics.fontSize, 26);
      expect(lyrics.fontWeight, 600);
      expect(lyrics.blurEnabled, isFalse);

      expect(find.byType(AlbumBlurFlow), findsOneWidget);
      expect(find.byType(AlbumFlowBackground), findsOneWidget);

      // The four top-bar actions live against the right edge, and the lyric
      // header no longer carries its own options button.
      for (final String key in <String>[
        'desktop-comments',
        'desktop-queue',
        'desktop-fullscreen',
        'desktop-more',
      ]) {
        expect(
          tester.getRect(find.byKey(ValueKey<String>(key))).left,
          greaterThan(1600 - 260),
          reason: '$key is not in the right-aligned group',
        );
      }
      expect(find.text('Aa'), findsNothing);

      final Rect rail = tester.getRect(
        find.byKey(const ValueKey<String>('desktop-seek-bar')),
      );
      final Rect thumb = tester.getRect(
        find.byKey(const ValueKey<String>('desktop-seek-thumb')),
      );
      expect(thumb.center.dy, closeTo(rail.center.dy, 0.01));
      expect(thumb.left, greaterThanOrEqualTo(rail.left));
      expect(thumb.center.dx - rail.left, closeTo(6, 0.6));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('queue and comments dock as overlay panels', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = _state();
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey<String>('desktop-queue')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackQueueView), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('desktop-panel-close')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackQueueView), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('desktop-comments')));
    await tester.pumpAndSettle();
    expect(find.byType(SongCommentsView), findsOneWidget);
    expect(find.textContaining('桌面评论'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard transport shortcuts drive the player', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = _state(playing: true);
    addTearDown(state.dispose);
    final GlobalKey screenshot = GlobalKey();
    await tester.pumpWidget(_app(state, key: screenshot));
    await tester.pumpAndSettle();
    expect(state.playing, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(state.playing, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(state.precisePosition.inSeconds, greaterThanOrEqualTo(4));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(state.volume, 0);

    expect(tester.takeException(), isNull);
    await _snapshot(tester, screenshot, 'desktop_now_playing');
    state.pause();
    await tester.pump();
  });
}
