import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/widgets/interaction_feedback.dart';
import 'package:lazer_nextgen/widgets/window_frame.dart';

const _track = Track(
  id: '1939575649',
  title: 'まにまに',
  artist: 'r-906 / 初音ミク',
  album: 'まにまに',
  duration: Duration(minutes: 4),
  coverSeed: 1,
  coverUrl: 'https://example.com/cover.jpg',
  translatedTitle: '测试译名',
);
const _playlist = Playlist(
  id: '12',
  name: '测试歌单详情',
  trackIds: [],
  coverSeed: 1,
  trackCount: 1,
);

class _Catalog extends Catalog {
  _Catalog({super.gateway});
  @override
  Future<UserCollections> userCollections(int uid) async =>
      const UserCollections(
        liked: Playlist(
          id: '99',
          name: '喜欢的音乐',
          trackIds: [],
          coverSeed: 1,
          trackCount: 1,
        ),
        created: [_playlist],
      );
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => home;
  @override
  HomeFeed? get home => const HomeFeed(
    recommended: [_playlist],
    featured: Album(
      id: '9',
      title: 'I Look To You',
      artist: 'Whitney Houston',
      year: '',
      coverSeed: 1,
      note: '',
    ),
    featuredTracks: [],
    quick: [],
    playlists: [_playlist],
    albums: [],
  );
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00.00]第一句歌词\n[00:02.00]第二句歌词\n[00:04.00]第三句歌词\n[00:06.00]第四句歌词',
    tlyric:
        '[00:00.00]第一句翻译\n[00:02.00]第二句翻译\n[00:04.00]第三句翻译\n[00:06.00]第四句翻译',
  );
  @override
  Future<List<Track>> playlistTracks(String id) async => [_track];
}

class _AuthGateway extends NeteaseGateway {
  _AuthGateway({this.qrCompletes = false});

  /// Whether the fake QR poll reports a confirmed scan. Widget tests that only
  /// want the sign-in card to stay open leave it at "waiting" — the panel
  /// polls immediately now, so a 803 would close the dialog on the first frame.
  final bool qrCompletes;

  static const status = GatewayLoginStatus(
    profile: GatewayUserProfile(
      userId: 7,
      nickname: '测试账户',
      vipType: 11,
      avatarUrl: 'https://example.com/avatar.jpg',
    ),
  );
  @override
  Future<GatewayLoginStatus> loginWithCookie(String cookie) async {
    sessionCookie = cookie;
    return status;
  }

  @override
  Future<GatewayLoginStatus> loginStatus() async => status;
  @override
  Future<Set<int>> likedSongIds(int uid) async => {1939575649};
  @override
  Future<String> createQrKey() async => 'fixture-key';
  @override
  Future<GatewayQrCheck> checkQrCode(String key, {String secureCaptcha = ''}) async {
    if (!qrCompletes) return const GatewayQrCheck(code: 801);
    sessionCookie = 'MUSIC_U=fixture';
    return const GatewayQrCheck(code: 803, cookie: 'MUSIC_U=fixture');
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('diag/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    final font = FontLoader('MiSans')
      ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Medium.ttf'))
      ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'title bar has an explicit text style outside a Material scaffold',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildLegacyTheme(),
            builder: (context, child) => Column(
              children: [
                const DesktopTitleBar(),
                Expanded(child: child!),
              ],
            ),
            home: const Scaffold(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text('Lazer'),
          matching: find.byType(RichText),
        ),
      );
      expect(rich.text.style?.decoration, TextDecoration.none);
      expect(
        rich.text.style?.color,
        buildLegacyTheme().colorScheme.onSurfaceVariant,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'ui_title_latest');
    },
  );

  test('confirmed QR adopts and persists a verified session', () async {
    final state = AppState(
      catalog: _Catalog(gateway: _AuthGateway(qrCompletes: true)),
    );
    addTearDown(state.dispose);
    final url = await state.beginQrLogin();
    expect(await state.pollQrLogin(url!), 803);
    expect(state.signedIn, true);
    expect(state.user.method, AuthMethod.qrcode);
  });

  test(
    'restored queue loads current lyrics without starting playback',
    () async {
      SharedPreferences.setMockInitialValues({
        'lazer_playback_queue_v1': jsonEncode({
          'index': 0,
          'tracks': [
            {
              'id': _track.id,
              'title': _track.title,
              'artist': _track.artist,
              'album': _track.album,
              'durationMs': 240000,
              'coverUrl': _track.coverUrl,
            },
          ],
        }),
      });
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.bootstrap();
      await Future<void>.delayed(Duration.zero);
      expect(state.current?.id, _track.id);
      expect(state.playing, false);
      expect(state.lyricsLoading, false);
      expect(state.lyrics, hasLength(4));
    },
  );

  testWidgets('control feedback respects the persisted off setting', (
    tester,
  ) async {
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    int pulses = 0;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'HapticFeedback.vibrate') pulses++;
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      InteractionFeedback(
        state: state,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: feedbackAction(context, () {}),
                child: const Text('触摸反馈'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('触摸反馈'));
    expect(pulses, 1);
    await state.setHapticsEnabled(false);
    await tester.tap(find.text('触摸反馈'));
    expect(pulses, 1);
    expect(
      (await SharedPreferences.getInstance()).getBool('lazer_haptics'),
      false,
    );
    await state.setLyricControlsSeconds(4);
    expect(
      (await SharedPreferences.getInstance()).getDouble(
        'lazer_lyric_controls_seconds',
      ),
      4,
    );
    await state.setLyricBlurEnabled(false);
    await state.setScrollRetention(.98);
    await state.setLyricResumeSeconds(3);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('lazer_lyric_blur'), false);
    expect(prefs.getDouble('lazer_scroll_retention'), .98);
    expect(prefs.getDouble('lazer_lyric_resume_seconds'), 3);
  });
}
