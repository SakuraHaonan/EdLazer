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
import 'package:lazer_nextgen/screens/now_playing_page.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/screens/playlist_detail_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/theme/design_tokens.dart';
import 'package:lazer_nextgen/widgets/interaction_feedback.dart';
import 'package:lazer_nextgen/widgets/plate_art.dart';
import 'package:lazer_nextgen/screens/login_page.dart';
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
  Future<GatewayQrCheck> checkQrCode(String key) async {
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

  testWidgets('mobile Me favorites entry opens the account liked playlist', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog(gateway: _AuthGateway()));
    addTearDown(state.dispose);
    await state.signInWithCookie('MUSIC_U=fixture');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: PlayerPage(state: state),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('我').first);
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('mobile-liked-playlist'));
    expect(entry, findsOneWidget);
    expect(
      find.descendant(of: entry, matching: find.text('我喜欢')),
      findsOneWidget,
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PlaylistDetailPage>(find.byType(PlaylistDetailPage))
          .playlist
          .id,
      '99',
    );
    expect(find.text('まにまに'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile account card contains only avatar and sign-out and grows with text size',
    (tester) async {
      final state = AppState(catalog: _Catalog(gateway: _AuthGateway()));
      addTearDown(state.dispose);
      addTearDown(tester.view.reset);
      await state.signInWithCookie('MUSIC_U=fixture');
      for (final width in [320.0, 390.0]) {
        for (final scale in [1.0, 1.6, 2.0]) {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          final key = GlobalKey();
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: buildAppTheme(),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: PlayerPage(key: ValueKey('$width-$scale'), state: state),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('我').first);
          await tester.pumpAndSettle();
          expect(find.text('测试账户'), findsNothing);
          expect(find.text('黑胶会员'), findsNothing);
          expect(find.text('退出登录'), findsOneWidget);
          expect(find.byType(PlateArt), findsWidgets);
          expect(
            tester.takeException(),
            isNull,
            reason: 'profile width=$width scale=$scale',
          );
          if (width == 320 && scale == 1) {
            await _capture(tester, key, 'ui_mobile_account_latest');
          }
        }
      }
    },
  );
  testWidgets(
    'four-digit track ordinal stays on one line at large text sizes',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: TrackRow(
                    track: _track,
                    index: 1002,
                    isCurrent: false,
                    onPlay: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final text = tester.widget<Text>(find.text('1002'));
      expect(text.maxLines, 1);
      expect(text.softWrap, false);
      expect(tester.getSize(find.text('1002')).height, lessThan(32));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'title bar has an explicit text style outside a Material scaffold',
    (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildAppTheme(),
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
      expect(rich.text.style?.color, AppColors.cloudDark);
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'ui_title_latest');
    },
  );

  test('confirmed QR adopts and persists a verified session', () async {
    final state = AppState(catalog: _Catalog(gateway: _AuthGateway()));
    addTearDown(state.dispose);
    final url = await state.beginQrLogin();
    expect(await state.pollQrLogin(url!), 803);
    expect(state.signedIn, true);
    expect(state.user.method, AuthMethod.qrcode);
  });

  testWidgets(
    'cookie login closes the dialog and synchronizes sidebar collections',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog(gateway: _AuthGateway()));
      addTearDown(state.dispose);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            home: PlayerPage(state: state),
          ),
        ),
      );
      await tester.tap(find.text('游客'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cookie'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'MUSIC_U=fixture');
      await tester.tap(find.widgetWithText(TextButton, '登录'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsNothing);
      expect(state.signedIn, true);
      expect(find.text('测试账户'), findsOneWidget);
      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.text('未在播放'), findsNothing);
      expect(tester.getRect(find.text('设置')).top, greaterThan(500));

      final marker = find.byKey(const ValueKey('sidebar-selection-marker'));
      final before = tester.getTopLeft(marker).dy;
      await tester.tap(find.text('搜索'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final during = tester.getTopLeft(marker).dy;
      expect(during, greaterThan(before));
      expect(during, lessThan(before + 44));
      await tester.pumpAndSettle();
      final field = find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(AnimatedContainer),
      );
      expect(tester.getSize(field.first).height, greaterThanOrEqualTo(52));
      await tester.tap(find.text('测试歌单详情').first);
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDetailView), findsOneWidget);
      expect(find.byType(PlaylistDetailPage), findsNothing);
      expect(find.text('我的歌单'), findsOneWidget);
      final row = find.byType(TrackRow).first;
      final hover = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      await hover.addPointer(location: Offset.zero);
      await hover.moveTo(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 1));
      final background = tester.widget<AnimatedContainer>(
        find
            .descendant(of: row, matching: find.byType(AnimatedContainer))
            .first,
      );
      expect(
        (background.decoration as BoxDecoration).borderRadius,
        BorderRadius.zero,
      );
      expect(background.clipBehavior, Clip.antiAlias);
      final painted = tester.widget<DecoratedBox>(
        find.descendant(of: row, matching: find.byType(DecoratedBox)).first,
      );
      final tint = (painted.decoration as BoxDecoration).color!;
      expect(
        tint.withValues(alpha: 1),
        AppColors.oatWarm,
        reason:
            'the first hover frame retains the paper RGB, with no interpolation from black',
      );
      await hover.removePointer();
      await tester.pump();
      await tester.tap(find.text('我').first);
      await tester.pumpAndSettle();
      expect(find.text('我喜欢的音乐'), findsNothing);
      expect(find.text('我创建的歌单 · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('mobile navigation, compact feature, and playlist details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          theme: buildAppTheme(),
          home: PlayerPage(state: state),
        ),
      ),
    );
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('设置'), findsNothing);
    expect(find.byType(InkWell), findsWidgets);
    await tester.pumpAndSettle();
    expect(find.text('推荐歌单'), findsOneWidget);
    expect(find.text('推荐专辑'), findsNothing);
    await _capture(tester, key, 'ui_mobile_shell');
    await tester.ensureVisible(find.text('测试歌单详情').first);
    await tester.tap(find.text('测试歌单详情').first);
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    expect(find.text('まにまに'), findsOneWidget);
    Future<void> backGesture(
      String method, [
      Map<String, Object?>? args,
    ]) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
      await tester.pump();
    }

    const start = <String, Object?>{
      'touchOffset': <double>[5, 300],
      'progress': 0.0,
      'swipeEdge': 0,
    };
    await backGesture('startBackGesture', start);
    await backGesture('updateBackGestureProgress', <String, Object?>{
      'x': 100.0,
      'y': 300.0,
      'progress': 0.4,
      'swipeEdge': 0,
    });
    await backGesture('cancelBackGesture');
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailPage), findsOneWidget);
    await backGesture('startBackGesture', start);
    await backGesture('updateBackGestureProgress', <String, Object?>{
      'x': 150.0,
      'y': 300.0,
      'progress': 0.6,
      'swipeEdge': 0,
    });
    await backGesture('commitBackGesture');
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistDetailPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'player adapts to phone, landscape and desktop; lyric controls hide and wake',
    (tester) async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      for (final size in [
        const Size(390, 844),
        const Size(320, 568),
        const Size(640, 360),
        const Size(1028, 674),
        const Size(800, 400),
        const Size(1360, 860),
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              theme: buildAppTheme(),
              home: NowPlayingPage(key: ValueKey(size), state: state),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'layout $size');
        final title = tester.widget<Text>(find.text(_track.title).first);
        expect(title.maxLines, 1);
        expect(title.overflow, TextOverflow.ellipsis);
        expect(find.text('测试译名'), findsOneWidget);
        if (size.width >= 720) {
          expect(find.text('第一句翻译'), findsOneWidget);
          expect(tester.getRect(find.byType(PlateArt).first).left, 32);
        }
        final transport = tester.getRect(
          find.byKey(const ValueKey('now-playing-transport')),
        );
        expect(transport.top, greaterThanOrEqualTo(0));
        expect(
          transport.bottom,
          lessThanOrEqualTo(size.height - 8),
          reason:
              'every media control must stay fully inside the viewport at $size',
        );
        final shuffled = state.shuffle;
        await tester.tap(find.byTooltip('随机播放'));
        await tester.pump();
        expect(
          state.shuffle,
          !shuffled,
          reason: 'the control is visible and hit-testable',
        );
        expect(
          find.ancestor(
            of: find.byType(PlateArt),
            matching: find.byType(ImageFiltered),
          ),
          findsNothing,
          reason: 'cover mode has a flat background',
        );
        if (size.width < 720 && size.height > 500) {
          expect(
            tester.getRect(find.byTooltip('循环播放')).right,
            closeTo(size.width - 24, 1),
            reason: 'transport fills the row through the right edge',
          );
        }
        await _capture(
          tester,
          key,
          size.width > 720
              ? 'ui_desktop_player_${size.width.toInt()}_${size.height.toInt()}'
              : 'ui_mobile_player',
        );
        if (size.width == 390) {
          await tester.longPress(find.byType(PlateArt).first);
          await tester.pumpAndSettle();
          expect(find.text('保存封面图片？'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('歌词'));
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byKey(const ValueKey('mobile-cover')), findsOneWidget);
          expect(find.byKey(const ValueKey('mobile-lyrics')), findsOneWidget);
          for (var frame = 0; frame < 40; frame++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          expect(find.text('第一句翻译'), findsOneWidget);
          await tester.pump(const Duration(seconds: 3));
          await tester.pump(const Duration(milliseconds: 250));
          final opacityFinder = find.ancestor(
            of: find.byTooltip('歌词'),
            matching: find.byType(AnimatedOpacity),
          );
          expect(
            tester.widget<AnimatedOpacity>(opacityFinder.first).opacity,
            0,
          );
          await tester.tapAt(const Offset(180, 190));
          await tester.pump();
          expect(
            tester.widget<AnimatedOpacity>(opacityFinder.first).opacity,
            1,
          );
        }
      }
      tester.view.reset();
    },
  );

  testWidgets('global touch feedback respects the persisted off setting', (
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
            body: TextButton(onPressed: () {}, child: const Text('触摸反馈')),
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
