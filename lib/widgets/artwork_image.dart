import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../utils/artwork.dart';

/// NetworkImage adds headers to HttpClient's default User-Agent. The NetEase
/// image CDN rejects that duplicated header, so set each header explicitly.
class ArtworkImage extends ImageProvider<ArtworkImage> {
  const ArtworkImage(this.url);
  final String url;

  @override
  Future<ArtworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  bool operator ==(Object other) => other is ArtworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  static final HttpClient _client = HttpClient()..autoUncompress = false;

  @override
  ImageStreamCompleter loadImage(
    ArtworkImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _load(ArtworkImage key, ImageDecoderCallback decode) async {
    try {
      final uri = Uri.parse(key.url);
      final request = await _client
          .getUrl(uri)
          .timeout(const Duration(seconds: 15));
      artworkHeaders.forEach(request.headers.set);
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw NetworkImageLoadException(
          statusCode: response.statusCode,
          uri: uri,
        );
      }
      final bytes = await consolidateHttpClientResponseBytes(response);
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      PaintingBinding.instance.imageCache.evict(key);
      rethrow;
    }
  }
}
