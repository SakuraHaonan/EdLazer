import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';

import 'artwork.dart';

/// Saves the same real artwork as the player, with explicitly set CDN headers.
Future<bool> saveCover(String url, String title) async {
  final client = HttpClient();
  Uint8List? bytes;
  try {
    for (final candidate in artworkCandidates(url)) {
      final request = await client
          .getUrl(Uri.parse(candidate))
          .timeout(const Duration(seconds: 15));
      artworkHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 403) {
        await response.drain<void>();
        continue;
      }
      if (response.statusCode != 200) {
        throw HttpException('Cover download failed');
      }
      bytes = await consolidateHttpClientResponseBytes(response);
      break;
    }
  } finally {
    client.close();
  }
  if (bytes == null || bytes.isEmpty) {
    throw const HttpException('Cover unavailable');
  }
  return saveCoverBytes(bytes, title);
}

/// Native export after the artwork request has completed successfully.
Future<bool> saveCoverBytes(Uint8List bytes, String title) async {
  final safeTitle = title.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  final name = safeTitle.isEmpty ? 'Lazer cover' : safeTitle;
  if (Platform.isAndroid || Platform.isIOS) {
    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw const FileSystemException('相册权限未开启');
    }
    await Gal.putImageBytes(bytes, name: name);
    return true;
  }
  final extension = bytes.length > 4 && bytes[0] == 0x89 && bytes[1] == 0x50
      ? 'png'
      : 'jpg';
  final location = await getSaveLocation(suggestedName: '$name.$extension');
  if (location == null) return false;
  await XFile.fromData(
    bytes,
    mimeType: extension == 'jpg' ? 'image/jpeg' : 'image/png',
    name: '$name.$extension',
  ).saveTo(location.path);
  return true;
}
