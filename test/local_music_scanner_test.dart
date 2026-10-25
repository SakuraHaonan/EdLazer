import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/local/local_library.dart';
import 'package:lazer_nextgen/local/local_music_scanner.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-scan-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<File> write(String relative, List<int> bytes) async {
    final File file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  test('finds audio files recursively and skips the rest', () async {
    await write('one.mp3', <int>[0x49, 0x44, 0x33]);
    await write('Album/two.flac', <int>[0x66, 0x4C, 0x61, 0x43]);
    await write('Album/notes.txt', <int>[1, 2, 3]);
    await write('.hidden/secret.mp3', <int>[0x49, 0x44, 0x33]);
    await write('cover.jpg', <int>[1, 2, 3]);
    final LocalScanResult result = await LocalMusicScanner().scan(root);
    expect(result.canceled, isFalse);
    expect(result.tracks.map((LocalTrack entry) => entry.track.title), <String>[
      'one',
      'two',
    ]);
    expect(
      result.tracks.every((LocalTrack entry) => entry.source == LocalTrackSource.scan),
      isTrue,
    );
    expect(result.tracks.every((LocalTrack entry) => entry.path.isNotEmpty), isTrue);
  });

  test('reuses entries whose size and mtime are unchanged', () async {
    await write('song.mp3', <int>[0x49, 0x44, 0x33]);
    final LocalScanResult first = await LocalMusicScanner().scan(root);
    expect(first.tracks, hasLength(1));
    final LocalScanResult second = await LocalMusicScanner().scan(
      root,
      existing: first.tracks,
    );
    expect(second.tracks, hasLength(1));
    expect(identical(second.tracks.single, first.tracks.single), isTrue);
  });

  test('reports progress and can be canceled', () async {
    await write('a.mp3', <int>[0x49, 0x44, 0x33]);
    await write('b.mp3', <int>[0x49, 0x44, 0x33]);
    final List<int> progress = <int>[];
    final LocalScanResult canceled = await LocalMusicScanner().scan(
      root,
      isCanceled: () => true,
      onProgress: (int count, String current) => progress.add(count),
    );
    expect(canceled.canceled, isTrue);
    expect(canceled.tracks, isEmpty);
    expect(progress, isEmpty);

    final LocalScanResult full = await LocalMusicScanner().scan(
      root,
      onProgress: (int count, String current) => progress.add(count),
    );
    expect(full.tracks, hasLength(2));
    expect(progress, <int>[1, 2]);
  });

  test('a missing root is reported instead of thrown', () async {
    final LocalScanResult result = await LocalMusicScanner().scan(
      Directory('${root.path}/gone'),
    );
    expect(result.tracks, isEmpty);
    expect(result.skipped, greaterThan(0));
  });
}
