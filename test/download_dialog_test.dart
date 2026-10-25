import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/downloads/download_dialog.dart';
import 'package:lazer_nextgen/legacy/legacy_theme.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Track _track = Track(
  id: '1',
  title: '夜の歌',
  artist: '音楽人',
  album: 'アルバム',
  duration: Duration(minutes: 3),
  coverSeed: 1,
);

void main() {
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    directory = await Directory.systemTemp.createTemp('lazer-download-dialog-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('offers all four tiers and remembers the chosen one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);
    await state.setDownloadDirectory(directory.path);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDownloadDialog(
                  context,
                  state,
                  tracks: const <Track>[_track],
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    for (final AudioQuality quality in AudioQuality.values) {
      expect(
        find.byKey(ValueKey<String>('download-quality-${quality.name}')),
        findsOneWidget,
        reason: 'missing ${quality.name}',
      );
    }
    expect(find.text(directory.path), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey<String>('download-quality-lossless')),
        matching: find.byType(Radio<AudioQuality>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('download-confirm')));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();

    expect(state.downloadQuality, AudioQuality.lossless);
    expect(state.downloadDirectory, directory.path);
    expect(find.byKey(const ValueKey<String>('download-confirm')), findsNothing);
  });

  testWidgets('a batch offers an album sub-folder', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppState state = AppState();
    addTearDown(state.dispose);
    await state.setDownloadDirectory(directory.path);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLegacyTheme(brightness: Brightness.dark),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDownloadDialog(
                  context,
                  state,
                  tracks: const <Track>[_track],
                  folderName: '专辑',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('创建「专辑」文件夹'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}
