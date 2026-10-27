import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/background_image.dart';

void main() {
  late Directory root;
  late Directory support;

  setUp(() {
    root = Directory.systemTemp.createTempSync('lazer-background-store');
    support = Directory('${root.path}${Platform.pathSeparator}support')
      ..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('copies picked bytes into the support directory', () async {
    final BackgroundImageStore store = BackgroundImageStore(
      directory: () async => support,
    );
    final Uint8List bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

    final String path = await store.write(bytes, sourceName: 'photo.JPEG');

    expect(path, startsWith(support.path));
    expect(File(path).readAsBytesSync(), bytes);
    final String name = _baseName(path);
    expect(name, startsWith('background_'));
    expect(name, endsWith('.jpeg'));
    expect(store.preferenceValue(path), name);
  });

  test('a renewed app container still finds the stored copy', () async {
    final BackgroundImageStore first = BackgroundImageStore(
      directory: () async => support,
    );
    final String written = await first.write(
      Uint8List.fromList(<int>[9, 8, 7]),
      sourceName: 'chosen.png',
    );
    final String name = _baseName(written);

    // iOS may move the app container between launches. The old absolute path
    // is now stale; the file still lives in the renamed directory.
    final Directory moved = Directory(
      '${root.path}${Platform.pathSeparator}renamed-support',
    );
    support.renameSync(moved.path);
    final BackgroundImageStore second = BackgroundImageStore(
      directory: () async => moved,
    );

    final String expected = '${moved.path}${Platform.pathSeparator}$name';
    expect(await second.restore(written), expected);
    expect(await second.restore(name), expected);
    expect(await second.restore(null), isNull);
  });

  test('stale absolute paths cannot orphan or delete foreign files', () async {
    final BackgroundImageStore store = BackgroundImageStore(
      directory: () async => support,
    );
    final String written = await store.write(
      Uint8List.fromList(<int>[5]),
      sourceName: 'chosen.png',
    );
    final String name = _baseName(written);

    final Directory moved = Directory(
      '${root.path}${Platform.pathSeparator}moved',
    );
    support.renameSync(moved.path);
    final BackgroundImageStore current = BackgroundImageStore(
      directory: () async => moved,
    );

    // Deleting with the old absolute path still removes the copy in the new
    // container.
    await current.delete(written);
    expect(
      File('${moved.path}${Platform.pathSeparator}$name').existsSync(),
      isFalse,
    );

    final File foreign = File('${root.path}${Platform.pathSeparator}family.png')
      ..writeAsBytesSync(<int>[1]);
    expect(current.preferenceValue(foreign.path), foreign.path);
    expect(await current.restore(foreign.path), foreign.path);
    await current.delete(foreign.path);
    expect(foreign.existsSync(), isTrue);
  });
}

String _baseName(String path) => path.split(RegExp(r'[/\\]')).last;
