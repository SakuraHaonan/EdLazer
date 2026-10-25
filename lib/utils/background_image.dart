import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';

/// Image formats the backdrop can decode, shared by the picker filter and the
/// extension keeper.
const List<String> _backgroundImageExtensions = <String>[
  'jpg',
  'jpeg',
  'png',
  'webp',
  'bmp',
  'gif',
];

const XTypeGroup _imageTypeGroup = XTypeGroup(
  label: '图片',
  extensions: _backgroundImageExtensions,
  // Android's picker filters by MIME type; desktop platforms use extensions.
  mimeTypes: <String>[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/bmp',
    'image/gif',
  ],
);

/// Prefix of the copies this app keeps; also how [deleteCustomBackgroundImage]
/// recognises files it may remove.
const String _filePrefix = 'background_';

/// Asks the platform picker for a picture and copies it into the app's support
/// directory. Returns the stored path, or null when the listener cancels.
///
/// Copying keeps the backdrop working after the original is moved or deleted.
/// The timestamped name also defeats Flutter's image cache, so picking a new
/// picture always shows the new one even when the old file is replaced.
Future<String?> pickCustomBackgroundImage() async {
  final XFile? file = await openFile(
    acceptedTypeGroups: const <XTypeGroup>[_imageTypeGroup],
  );
  if (file == null) return null;
  final Directory directory = await getApplicationSupportDirectory();
  final String extension = _extensionOf(file.name);
  final String target =
      '${directory.path}${Platform.pathSeparator}$_filePrefix'
      '${DateTime.now().millisecondsSinceEpoch}$extension';
  // Reading through XFile keeps this working on Android, where the picker can
  // hand back a content URI instead of a filesystem path.
  final Uint8List bytes = await file.readAsBytes();
  await File(target).writeAsBytes(bytes, flush: true);
  return target;
}

/// Removes a stored backdrop copy. Only files this app wrote are touched, so a
/// stale preference can never delete a picture outside the support directory.
Future<void> deleteCustomBackgroundImage(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final Directory directory = await getApplicationSupportDirectory();
    final String name = path.split(RegExp(r'[/\\]')).last;
    if (!path.startsWith(directory.path) || !name.startsWith(_filePrefix)) {
      return;
    }
    final File file = File(path);
    if (await file.exists()) await file.delete();
  } catch (_) {
    // A leftover copy is harmless; never fail the settings action over it.
  }
}

String _extensionOf(String path) {
  final String name = path.split(RegExp(r'[/\\]')).last;
  final int dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '.png';
  final String extension = name.substring(dot).toLowerCase();
  return extension.length <= 6 ? extension : '.png';
}
