import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/data/audio_quality.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/local/local_library.dart';

Track _track(String id, String title) => Track(
  id: id,
  title: title,
  artist: '音乐人',
  album: '专辑',
  duration: const Duration(minutes: 3),
  coverSeed: 0,
);

void main() {
  late Directory root;
  late Directory support;
  late Directory documents;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lazer-local-library-test-');
    support = Directory('${root.path}/support');
    documents = Directory('${root.path}/documents');
    await support.create(recursive: true);
    await documents.create(recursive: true);
  });
  tearDown(() async => root.delete(recursive: true));

  LocalLibrary create() => LocalLibrary(
    supportDirectory: () async => support,
    documentsDirectory: () async => documents,
  );

  Future<File> writeFile(String name, List<int> bytes) async {
    final File file = File('${documents.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  String native(String path) {
    String value = File(path).absolute.path;
    if (Platform.isWindows) value = value.replaceAll('/', '\\');
    return value;
  }

  test('round-trips entries through the manifest', () async {
    final File file = await writeFile('music/a.mp3', <int>[1, 2, 3]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('42', '曲目'),
        path: file.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.lossless,
        bytes: 3,
        modifiedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        addedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      ),
    ]);
    expect(library.count, 1);
    expect(library.tracks.single.track.localPath, native(file.path));

    final LocalLibrary reopened = create();
    await reopened.load();
    expect(reopened.count, 1);
    final LocalTrack entry = reopened.tracks.single;
    expect(entry.track.title, '曲目');
    expect(entry.path, native(file.path));
    expect(entry.quality, AudioQuality.lossless);
    expect(entry.source, LocalTrackSource.download);
    expect(entry.track.localPath, native(file.path));

    final String manifest = await File(
      '${support.path}/local_library.json',
    ).readAsString();
    expect(manifest, contains('documents:music/a.mp3'));
  });

  test('flags files that disappeared without dropping the entry', () async {
    final File file = await writeFile('missing.mp3', <int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('7', '走了'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await file.delete();
    await library.refreshMissing();
    expect(library.tracks.single.missing, isTrue);
    expect(library.localFileFor(_track('7', '走了')), isNull);
    await library.clearMissing();
    expect(library.count, 0);
  });

  test('prefers the requested quality and then the highest tier', () async {
    final File low = await writeFile('low.mp3', <int>[1]);
    final File high = await writeFile('high.flac', <int>[2]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('9', '音质'),
        path: low.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.exhigh,
        addedAt: DateTime.fromMillisecondsSinceEpoch(100),
        modifiedAt: DateTime.now(),
      ),
      LocalTrack(
        track: _track('9', '音质'),
        path: high.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.lossless,
        addedAt: DateTime.fromMillisecondsSinceEpoch(200),
        modifiedAt: DateTime.now(),
      ),
    ]);
    expect(
      library.localFileFor(_track('9', '音质'))?.path,
      native(high.path),
    );
    expect(
      library
          .localFileFor(
            _track('9', '音质'),
            quality: AudioQuality.exhigh,
          )
          ?.path,
      native(low.path),
    );
  });

  test('deleting a download removes the file, a scan only the record', () async {
    final File downloaded = await writeFile('download.mp3', <int>[1]);
    final File scanned = await writeFile('scan.mp3', <int>[2]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('1', '下载'),
        path: downloaded.path,
        source: LocalTrackSource.download,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
      LocalTrack(
        track: _track('2', '扫描'),
        path: scanned.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await library.remove(
      library.entryForPath(downloaded.path)!,
      deleteFile: true,
    );
    await library.remove(
      library.entryForPath(scanned.path)!,
      deleteFile: true,
    );
    expect(await downloaded.exists(), isFalse);
    expect(await scanned.exists(), isTrue);
    expect(library.count, 0);
  });

  test('the same path is indexed once and keeps the download source', () async {
    final File file = await writeFile('same.mp3', <int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('scan', '扫描'),
        path: file.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('download', '下载'),
        path: file.path,
        source: LocalTrackSource.download,
        quality: AudioQuality.exhigh,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    expect(library.count, 1);
    expect(library.tracks.single.source, LocalTrackSource.download);
    expect(library.tracks.single.track.id, 'download');
  });

  test('scan roots persist and can drop only their scanned entries', () async {
    final Directory music = Directory('${root.path}/Music');
    await music.create(recursive: true);
    final File inside = File('${music.path}/inside.mp3');
    await inside.writeAsBytes(<int>[1]);
    final LocalLibrary library = create();
    await library.load();
    await library.addScanRoot(music.path);
    await library.addTracks(<LocalTrack>[
      LocalTrack(
        track: _track('inside', '扫描'),
        path: inside.path,
        source: LocalTrackSource.scan,
        addedAt: DateTime.now(),
        modifiedAt: DateTime.now(),
      ),
    ]);
    final LocalLibrary reopened = create();
    await reopened.load();
    expect(reopened.scanRoots, <String>[native(music.path)]);
    await reopened.removeScannedUnder(music.path);
    expect(reopened.count, 0);
    expect(await inside.exists(), isTrue);
  });
}
