import '../cache/media_cache.dart';
import '../utils/artwork.dart';

/// System players use the very same disk artwork as the in-app player.
class MediaArtworkCache {
  Future<Uri?> resolve(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      final String key = enlargedArtworkUrl(url) ?? url;
      return (await ArtworkCache.shared.file(key))?.uri;
    } catch (_) {
      // Artwork failure must not stop playback or media key callbacks.
      return null;
    }
  }
}
