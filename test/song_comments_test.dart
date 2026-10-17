import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/data/song_comments.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/gateway/transport.dart';
import 'package:lazer_nextgen/screens/login_page.dart';
import 'package:lazer_nextgen/screens/now_playing_page.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/state/song_comments_controller.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/playback_queue_view.dart';
import 'package:lazer_nextgen/widgets/song_comments_view.dart';
import 'package:lazer_nextgen/widgets/volume_control.dart';

Map<String, dynamic> _comment(int id, {bool liked = false, int count = 10}) => {
  'commentId': id,
  'content': 'Comment $id · 在音乐里留下一点今天的心情。',
  'time': 1792080000000,
  'liked': liked,
  'likedCount': count,
  'user': {'userId': id + 100, 'nickname': 'Listener $id'},
};
Map<String, dynamic> _page({
  List<int> hot = const [1],
  List<int> latest = const [2],
  bool more = false,
}) => {
  'code': 200,
  'total': 120,
  'more': more,
  'hotComments': hot.map(_comment).toList(),
  'comments': latest.map(_comment).toList(),
};

class _Gateway extends NeteaseGateway {
  final reads = <(int, int)>[];
  final likes = <(int, int, bool)>[];
  Future<Map<String, dynamic>> Function(int, int) read = (_, _) async =>
      _page();
  Future<void> Function(int, int, bool) react = (_, _, _) async {};
  @override
  Future<Map<String, dynamic>> songComments(
    int songId, {
    int limit = 20,
    int offset = 0,
  }) {
    reads.add((songId, offset));
    return read(songId, offset);
  }

  @override
  Future<void> setSongCommentLiked(int songId, int commentId, bool liked) {
    likes.add((songId, commentId, liked));
    return react(songId, commentId, liked);
  }

  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
  @override
  Future<String> createQrKey() async => 'fixture-key';
  @override
  Future<String> createQrCodeUrl(String key) async =>
      'https://music.163.com/login?codekey=$key';
  @override
  Future<GatewayQrCheck> checkQrCode(String key, {String secureCaptcha = ''}) async =>
      const GatewayQrCheck(code: 801);
}

class _Catalog extends Catalog {
  _Catalog(_Gateway gateway) : super(gateway: gateway);
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    lrc: '[00:00]夜色落在窗前\n[00:02]音乐仍在继续\n[00:04]把今天轻轻收藏',
    tlyric:
        '[00:00]Night falls at the window\n[00:02]The music carries on\n[00:04]Keep a little of today',
  );
}

class _SignedInState extends AppState {
  _SignedInState(_Gateway gateway) : super(catalog: _Catalog(gateway));
  @override
  SessionUser get user => const SessionUser(
    name: 'Tester',
    handle: '@tester',
    method: AuthMethod.cookie,
    detail: '',
    userId: 7,
  );
  @override
  bool get signedIn => true;
  @override
  bool get isGuest => false;
}

Future<void> _snapshot(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PROBES')) return;
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('diag/$name.png').writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late Directory directory;
  late File artwork;
  late Track track;
  setUpAll(() async {
    await (FontLoader('MiSans')
          ..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Semibold.ttf'))
          ..addFont(rootBundle.load('assets/fonts/MiSans-Bold.ttf')))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    directory = await Directory.systemTemp.createTemp('lazer_comments_');
    artwork = File('${directory.path}/cover.png');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 400, 400),
      Paint()..color = const Color(0xff3d514b),
    );
    canvas.drawCircle(
      const Offset(200, 200),
      145,
      Paint()..color = const Color(0xffd2b7a2),
    );
    canvas.drawCircle(
      const Offset(200, 200),
      93,
      Paint()..color = const Color(0xff64736b),
    );
    canvas.drawCircle(
      const Offset(200, 200),
      15,
      Paint()..color = const Color(0xffeee8d7),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(400, 400);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await artwork.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    track = Track(
      id: '42',
      title: '晚风与唱片',
      artist: 'Lazer Sessions',
      album: '留在今天',
      duration: const Duration(minutes: 4, seconds: 12),
      coverSeed: 1,
      coverUrl: artwork.uri.toString(),
      translatedTitle: 'Evening notes',
    );
  });
  tearDownAll(() async {
    await artwork.delete();
    await directory.delete();
  });

  test(
    'parses service comment IDs, nullable metadata, avatars and quoted replies',
    () {
      final comment = SongComment.fromJson({
        ..._comment(9646640244),
        'likedCount': '120',
        'user': {
          'userId': 7,
          'nickname': '名字',
          'avatarUrl': 'http://p1.music.126.net/a.jpg',
        },
        'ipLocation': null,
        'beReplied': [
          {
            'content': 'Earlier comment',
            'user': {'nickname': 'Other'},
          },
        ],
      });
      expect(comment.id, 9646640244);
      expect(comment.likedCount, 120);
      expect(comment.avatarUrl, 'https://p1.music.126.net/a.jpg');
      expect(comment.replies.single.author, 'Other');
      expect(comment.location, isNull);
    },
  );

  test(
    'paging uses received offsets, deduplicates rows and stops on an empty page',
    () async {
      final gateway = _Gateway();
      gateway.read = (_, offset) async => offset == 0
          ? _page(latest: [1, 2], more: true)
          : offset == 2
          ? _page(hot: [], latest: [2, 3], more: true)
          : _page(hot: [], latest: [], more: true);
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 0);
      expect(controller.hot.map((c) => c.id), [1]);
      expect(controller.latest.map((c) => c.id), [2]);
      await controller.loadMore();
      expect(controller.latest.map((c) => c.id), [2, 3]);
      await controller.loadMore();
      await controller.loadMore();
      expect(controller.hasMore, false);
      expect(gateway.reads, [(42, 0), (42, 2), (42, 4)]);
      await controller.toggleLike(1);
      expect(gateway.likes, isEmpty);
    },
  );

  test('late pages cannot replace a newer song or disposed state', () async {
    final gateway = _Gateway();
    final old = Completer<Map<String, dynamic>>(),
        newer = Completer<Map<String, dynamic>>();
    gateway.read = (song, _) => song == 42 ? old.future : newer.future;
    final controller = SongCommentsController(gateway);
    final first = controller.openSong('42', accountId: 7);
    final second = controller.openSong('43', accountId: 7);
    newer.complete(_page(hot: [], latest: [43]));
    await second;
    old.complete(_page(latest: [42]));
    await first;
    expect(controller.trackId, '43');
    expect(controller.latest.single.id, 43);
    final pending = Completer<Map<String, dynamic>>();
    gateway.read = (_, _) => pending.future;
    final last = controller.openSong('44', accountId: 7);
    controller.dispose();
    pending.complete(_page());
    await last;
  });

  test(
    'likes update immediately, serialize each comment and roll back on failure',
    () async {
      final gateway = _Gateway();
      var reaction = Completer<void>();
      gateway.react = (_, _, _) => reaction.future;
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      final like = controller.toggleLike(1);
      expect(controller.hot.single.liked, true);
      expect(controller.hot.single.likedCount, 11);
      await controller.toggleLike(1);
      await controller.refresh();
      expect(gateway.likes, [(42, 1, true)]);
      expect(gateway.reads, [(42, 0)]);
      reaction.completeError(GatewayServiceException(500, '/comment/like'));
      await like;
      expect(controller.hot.single.liked, false);
      expect(controller.hot.single.likedCount, 10);
      expect(controller.actionError, isNotNull);
      reaction = Completer<void>();
      final retry = controller.toggleLike(1);
      reaction.complete();
      await retry;
      expect(controller.hot.single.liked, true);
      final unlike = controller.toggleLike(1);
      await unlike;
      expect(controller.hot.single.liked, false);
      expect(controller.hot.single.likedCount, 10);
      expect(controller.isLiking(1), false);
      gateway.read = (_, _) async => {
        ..._page(),
        'hotComments': [_comment(1, count: 50)],
      };
      await controller.refresh();
      expect(
        controller.hot.single.likedCount,
        50,
        reason: 'refresh re-reads server counts after completed reactions',
      );
      gateway.react = (_, _, _) async {
        throw GatewayServiceException(301, '/comment/like');
      };
      await controller.toggleLike(1);
      expect(controller.loginRequired, true);
      expect(controller.hot.single.liked, false);
      controller.dismissActionError();
      expect(controller.loginRequired, false);
    },
  );

  test(
    'session changes clear reactions and old reaction failures stay on their song',
    () async {
      final gateway = _Gateway();
      final reaction = Completer<void>();
      gateway.react = (_, _, _) => reaction.future;
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      final like = controller.toggleLike(1);
      await controller.openSong('43', accountId: 8);
      reaction.completeError(GatewayServiceException(301, '/comment/like'));
      await like;
      expect(controller.actionError, isNull);
      expect(controller.hot.single.liked, false);
      expect(controller.isLiking(1), false);
      await controller.openSong('43', accountId: 0);
      expect(gateway.reads.last, (43, 0));
      expect(gateway.reads, hasLength(3));
    },
  );

  test(
    'a failed next page retains rows and retries exactly that offset',
    () async {
      final gateway = _Gateway();
      var failed = false;
      gateway.read = (_, offset) async {
        if (offset == 0) return _page(more: true);
        if (!failed) {
          failed = true;
          throw StateError('offline');
        }
        return _page(hot: [], latest: [3]);
      };
      final controller = SongCommentsController(gateway);
      addTearDown(controller.dispose);
      await controller.openSong('42', accountId: 7);
      await controller.loadMore();
      expect(controller.latest.single.id, 2);
      expect(controller.error, isNotNull);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.latest.map((c) => c.id), [2, 3]);
      expect(gateway.reads, [(42, 0), (42, 1), (42, 1)]);
    },
  );

  for (final size in [
    const Size(800, 400),
    const Size(1100, 760),
    const Size(1440, 900),
  ]) {
    testWidgets('desktop dock and comments stay usable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = _Gateway();
      final state = _SignedInState(gateway);
      addTearDown(state.dispose);
      final next = Track.fromJson({
        ...track.toJson(),
        'id': '43',
        'title': '下一首歌',
      });
      state.playQueue([track, next]);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            theme: buildAppTheme(
              brightness: size.width == 1100
                  ? Brightness.light
                  : Brightness.dark,
            ),
            home: NowPlayingPage(state: state),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect(gateway.reads, isEmpty, reason: 'comments load only on opening');
      final dock = tester.getRect(
        find.byKey(const ValueKey('now-playing-transport')),
      );
      expect(dock.width, greaterThan(size.width * .8));
      expect(dock.bottom, lessThanOrEqualTo(size.height));
      expect(find.byType(VolumeControl), findsOneWidget);
      await _snapshot(tester, key, 'desktop_workspace_${size.width.toInt()}');
      await tester.tap(find.byTooltip('查看评论'));
      await tester.pumpAndSettle();
      expect(gateway.reads, [(42, 0)]);
      expect(find.byType(SongCommentsView), findsOneWidget);
      expect(find.textContaining('Comment 1'), findsOneWidget);
      if (size.height > 500) {
        await tester.tap(find.byTooltip('点赞').first);
        await tester.pumpAndSettle();
        expect(gateway.likes, [(42, 1, true)]);
        expect(find.byTooltip('取消点赞'), findsOneWidget);
      }
      await _snapshot(tester, key, 'desktop_comments_${size.width.toInt()}');
      await tester.tap(find.byTooltip('播放队列'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackQueueView), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(SongCommentsView), findsNothing);
      await _snapshot(tester, key, 'desktop_queue_${size.width.toInt()}');
      for (var i = 0; i < 10; i++) {
        state.seek(i / 100);
        await tester.pump();
      }
      expect(gateway.reads, hasLength(1));
      await tester.tap(find.text('歌词').first);
      await tester.pumpAndSettle();
      expect(find.byType(LyricViewport), findsOneWidget);
      await tester.tap(find.byTooltip('查看评论'));
      await tester.pumpAndSettle();
      expect(
        gateway.reads,
        hasLength(1),
        reason: 'switching panes retains the current page',
      );
      await tester.tap(find.byTooltip('下一首'));
      await tester.pumpAndSettle();
      expect(state.current?.id, '43');
      expect(gateway.reads.last, (43, 0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'guests can read mobile comments; liking opens sign-in without sending a reaction',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final gateway = _Gateway();
      final state = AppState(catalog: _Catalog(gateway));
      addTearDown(state.dispose);
      state.playQueue([track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: NowPlayingPage(state: state),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看评论'));
      await tester.pumpAndSettle();
      expect(find.byType(SongCommentsView), findsOneWidget);
      expect(gateway.reads, [(42, 0)]);
      await tester.tap(find.byTooltip('登录后点赞').first);
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(gateway.likes, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭').last);
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
