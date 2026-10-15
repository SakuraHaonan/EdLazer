import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/artwork.dart';

/// Local artwork works with all system players, including native clients that
/// cannot attach the headers required by the NetEase image CDN.
class MediaArtworkCache {
  final _pending = <String, Future<Uri?>>{};
  Future<Uri?> resolve(String? url) {
    if (url == null || url.isEmpty) return Future.value();
    return _pending.putIfAbsent(url, () => _download(url));
  }

  Future<Uri?> _download(String url) async {
    final client = HttpClient();
    try {
      final directory = Directory(
        '${(await getTemporaryDirectory()).path}/lazer_media_art',
      );
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}/${sha256.convert(utf8.encode(url))}.img',
      );
      if (await file.exists() && await file.length() > 0) return file.uri;
      for (final candidate in artworkCandidates(url)) {
        final request = await client
            .getUrl(Uri.parse(candidate))
            .timeout(const Duration(seconds: 15));
        artworkHeaders.forEach(request.headers.set);
        final response = await request.close().timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200) {
          await response.drain<void>();
          continue;
        }
        final bytes = await consolidateHttpClientResponseBytes(
          response,
        ).timeout(const Duration(seconds: 15));
        if (bytes.isEmpty) continue;
        await file.writeAsBytes(bytes, flush: true);
        return file.uri;
      }
    } catch (_) {
      // Artwork failure must not stop playback or media key callbacks.
    } finally {
      client.close(force: true);
    }
    _pending.remove(url);
    return null;
  }
}
