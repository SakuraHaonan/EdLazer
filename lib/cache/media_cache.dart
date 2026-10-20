import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../utils/artwork.dart';
import 'disk_cache.dart';

/// One persistent cover store shared by widgets, system controls and export.
class ArtworkCache {
  ArtworkCache({DiskCache? disk, List<String> Function(String)? candidates})
    : disk = disk ?? DiskCache.shared,
      _candidates = candidates ?? artworkCandidates;
  static final shared = ArtworkCache();
  final DiskCache disk;
  final List<String> Function(String) _candidates;
  final _pending = <String, Future<Uint8List>>{};

  /// Normalises a cover URL without rewriting its CDN resize directive.
  ///
  /// The previous key collapsed every rendition to the 1024 px URL, so a
  /// 44 dp thumbnail still downloaded and decoded a 1024² JPEG. The key now
  /// keeps the requested `param=NyN`, and the widgets decide the rendition.
  String _key(String url) => normalizedArtworkUrl(url) ?? url;

  Future<Uint8List> bytes(String url) {
    final key = _key(url);
    return _pending.putIfAbsent(key, () async {
      try {
        return await _load(key);
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<Uint8List> _load(String key) async {
    if (key.startsWith('file:')) {
      return File.fromUri(Uri.parse(key)).readAsBytes();
    }
    final cached = await disk.find(CacheBucket.artwork, key);
    if (cached != null) {
      try {
        return await cached.readAsBytes();
      } catch (_) {}
    }
    final client = HttpClient()..autoUncompress = false;
    try {
      Object? failure;
      for (final candidate in _candidates(key)) {
        try {
          final uri = Uri.parse(candidate);
          final request = await client
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
          final builder = BytesBuilder(copy: false);
          await for (final chunk in response.timeout(
            const Duration(seconds: 15),
          )) {
            builder.add(chunk);
            if (builder.length > 20 * 1024 * 1024) {
              throw const HttpException('Artwork too large');
            }
          }
          final bytes = builder.takeBytes();
          if (bytes.isEmpty ||
              (response.contentLength >= 0 &&
                  bytes.length != response.contentLength)) {
            throw const HttpException('Incomplete artwork');
          }
          await disk.put(CacheBucket.artwork, key, () => Stream.value(bytes));
          return bytes;
        } catch (error) {
          failure = error;
        }
      }
      throw failure ?? const HttpException('Artwork unavailable');
    } finally {
      client.close(force: true);
    }
  }

  Future<File?> file(String url) async {
    final key = _key(url);
    if (key.startsWith('file:')) return File.fromUri(Uri.parse(key));
    await bytes(key);
    return disk.find(CacheBucket.artwork, key);
  }

  Future<void> evict(String url) => disk.remove(CacheBucket.artwork, _key(url));
}

/// First playback streams immediately; a complete background download is used
/// on subsequent plays, even after restarting the application or going offline.
class AudioCache {
  AudioCache({DiskCache? disk}) : disk = disk ?? DiskCache.shared;
  final DiskCache disk;
  final _pending = <String, Future<File?>>{};
  static const _formats = ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'wav', 'mp4'];

  Future<File?> find(String trackId) async {
    for (final extension in _formats) {
      final file = await disk.find(
        CacheBucket.audio,
        trackId,
        extension: extension,
      );
      if (file != null) return file;
    }
    return null;
  }

  Future<File?> store(String trackId, String url, {String? format}) =>
      _pending.putIfAbsent(trackId, () async {
        try {
          return await _download(trackId, url, format);
        } finally {
          _pending.remove(trackId);
        }
      });

  Future<File?> _download(String trackId, String url, String? format) async {
    final cached = await find(trackId);
    if (cached != null) return cached;
    final client = HttpClient()..autoUncompress = false;
    try {
      final uri = Uri.parse(url);
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/');
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != HttpStatus.ok) return null;
      final type = response.headers.contentType?.mimeType ?? '';
      if (type.startsWith('text/') || type.contains('json')) return null;
      final suffix = uri.path.split('.').last.toLowerCase();
      final extension = _formats.contains(format?.toLowerCase())
          ? format!.toLowerCase()
          : _formats.contains(suffix)
          ? suffix
          : type.contains('flac')
          ? 'flac'
          : type.contains('mp4')
          ? 'm4a'
          : 'mp3';
      return await disk.put(
        CacheBucket.audio,
        trackId,
        () => response.timeout(const Duration(seconds: 30)),
        extension: extension,
        expectedLength: response.contentLength,
        maxBytes: 200 * 1024 * 1024,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
