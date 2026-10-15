import '../cache/media_cache.dart';

/// System players use the very same disk artwork as the in-app player.
class MediaArtworkCache {
  Future<Uri?> resolve(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      return (await ArtworkCache.shared.file(url))?.uri;
    } catch (_) {
      // Artwork failure must not stop playback or media key callbacks.
      return null;
    }
  }
}
