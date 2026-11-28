import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:edlazer_nextgen/data/audio_quality.dart';
import 'package:edlazer_nextgen/data/catalog.dart';
import 'package:edlazer_nextgen/data/models.dart';
import 'package:edlazer_nextgen/diagnostics/build_info.dart';
import 'package:edlazer_nextgen/gateway/gateway.dart';
import 'package:edlazer_nextgen/legacy/legacy_shell.dart';
import 'package:edlazer_nextgen/legacy/legacy_theme.dart';
import 'package:edlazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Track _track = Track(
  id: '1939575649',
  title: 'パベル',
  artist: 'いよわ',
  album: 'パベル',
  duration: Duration(minutes: 2, seconds: 26),
  coverSeed: 3,
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
  Future<List<Track>> playlistTracks(String id) async => <Track>[_track];

  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => null;
}

Widget _app(AppState state) => MaterialApp(
  theme: buildLegacyTheme(brightness: Brightness.dark),
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: child!,
  ),
  home: LegacyShell(state: state),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('stamped versions stay display-only', () {
    expect(BuildInfo.version, '2.0.0-beta.16');
    expect(BuildInfo.displayVersion, 'v2.0.0-beta.16');
    expect(BuildInfo.versionFromStamp('v2.0.0-beta.16+16'), '2.0.0-beta.16');
    expect(BuildInfo.versionFromStamp('2.0.0-beta.2+5'), '2.0.0-beta.2');
    expect(BuildInfo.versionFromStamp('1.5'), '1.5.0');
    expect(BuildInfo.versionFromStamp('nextgen'), isNull);
    expect(BuildInfo.versionFromStamp(''), isNull);
    expect(BuildInfo.versionFromStamp('v2.0-beta..1'), isNull);
  });

  test('sources no longer contain an update client', () {
    const List<String> forbidden = <String>[
      'api.github.com/repos',
      'org.haonan.edlazer/updates',
      'UpdateChecker',
      'checkForUpdates',
      'showUpdateDialog',
      'autoCheckUpdates',
      'Lazer-Updater',
      'checkUpdatesFromSettings',
    ];
    final List<String> hits = <String>[];
    for (final String root in <String>[
      'lib',
      'android',
      'ios',
      'macos',
      'linux',
      'windows',
    ]) {
      for (final FileSystemEntity entity in Directory(
        root,
      ).listSync(recursive: true)) {
        if (entity is! File) continue;
        final String path = entity.path;
        if (!path.endsWith('.dart') &&
            !path.endsWith('.kt') &&
            !path.endsWith('.swift') &&
            !path.endsWith('.m') &&
            !path.endsWith('.xml')) {
          continue;
        }
        final String text = entity.readAsStringSync();
        for (final String needle in forbidden) {
          if (text.contains(needle)) hits.add('$path contains $needle');
        }
      }
    }
    expect(hits, isEmpty);

    final List<String> leftover = File('lib/state/app_state.dart')
        .readAsLinesSync()
        .where(
          (String line) =>
              line.contains('lazer_skipped_update') ||
              line.contains('lazer_update_checked_at') ||
              line.contains('edlazer_skipped_update') ||
              line.contains('edlazer_update_checked_at'),
        )
        .toList();
    expect(leftover, isNotEmpty);
    for (final String line in leftover) {
      expect(
        line,
        contains('prefs.remove'),
        reason: 'obsolete update preferences may only be deleted: $line',
      );
    }
  });

  test(
    'bootstrap deletes obsolete update keys and keeps playback prefs',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'lazer_skipped_update': '2.0.0-beta.9',
        'lazer_update_checked_at': 42,
        'lazer_volume': 0.4,
      });
      final AppState state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.bootstrap();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('lazer_skipped_update'), isNull);
      expect(prefs.getInt('lazer_update_checked_at'), isNull);
      expect(prefs.getString('edlazer_skipped_update'), isNull);
      expect(prefs.getInt('edlazer_update_checked_at'), isNull);
      expect(prefs.getDouble('lazer_volume'), isNull);
      expect(prefs.getDouble('edlazer_volume'), 0.4);
      expect(state.volume, closeTo(0.4, 0.001));
    },
  );

  testWidgets('startup does not offer an update', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(state));
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('前往下载'), findsNothing);
    expect(find.text('跳过此版本'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings keep the build version and omit update controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState(catalog: _Catalog());
    addTearDown(state.dispose);
    await tester.pumpWidget(_app(state));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('rail-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').last);
    await tester.pumpAndSettle();

    expect(find.text('EdLazer'), findsWidgets);
    expect(find.text(BuildInfo.displayVersion), findsOneWidget);
    expect(find.text('提交 ${BuildInfo.shortCommit}'), findsOneWidget);
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('从 GitHub 获取最新版本'), findsNothing);
    expect(find.text('发现新版本'), findsNothing);
    expect(find.text('恢复提醒'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
