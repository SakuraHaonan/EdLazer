/// Artwork URL helpers, ported from the reference backend
/// (`LazerLibrary.kt`: normalizedArtworkUrl / enlargedArtworkUrl).
///
/// NetEase CDN images scale server-side through the `?param=NyN` query
/// parameter: the CDN resizes the original JPEG and caches the result, so
/// every consumer of one artwork at one display size shares a single,
/// small cache entry instead of the full-resolution original.
library;

/// Matches an existing `param=<w>y<h>` resize directive.
final RegExp _paramSize = RegExp(r'([?&]param=)\d+y\d+', caseSensitive: false);

bool _isNeteaseCdn(String host) =>
    host.endsWith('.music.126.net') || host.endsWith('.music.163.com');

/// Normalizes a raw cover URL to a fetchable https URL, or null.
///
/// Accepts `//host/path` protocol-relative and `http(s)://` URLs, upgrading
/// http to https. Local `file://` paths and anything else yield null here —
/// [enlargedArtworkUrl] still passes `file://` through untouched.
String? normalizedArtworkUrl(String? raw) {
  final String trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('//')) return 'https:$trimmed';
  final String lower = trimmed.toLowerCase();
  if (lower.startsWith('http://')) {
    return 'https://${trimmed.substring('http://'.length)}';
  }
  if (lower.startsWith('https://')) return trimmed;
  return null;
}

/// Rewrites [raw] to the CDN-resized variant at [sizePx]x[sizePx].
///
/// Non-NetEase hosts, local `file://` covers, and URLs whose `param`
/// directive has an exotic shape are returned as-is (normalized only).
String? enlargedArtworkUrl(String? raw, {int sizePx = 1024}) {
  final String? normalized = normalizedArtworkUrl(raw);
  if (normalized != null) {
    final Uri? uri = Uri.tryParse(normalized);
    if (uri == null || !_isNeteaseCdn(uri.host)) return normalized;
    // Already carries a `NyN` directive — swap the dimensions, keep the rest.
    final RegExpMatch? sized = _paramSize.firstMatch(normalized);
    if (sized != null) {
      return normalized.replaceFirst(
        _paramSize,
        '${sized.group(1)}$sizePx'
        'y$sizePx',
      );
    }
    final String sep = normalized.contains('?') ? '&' : '?';
    final String fragment = uri.fragment.isEmpty ? '' : '#${uri.fragment}';
    // The directive belongs to the query, so it goes ahead of any fragment.
    final String base = uri.fragment.isEmpty
        ? normalized
        : normalized.substring(0, normalized.length - fragment.length);
    return '$base$sep'
        'param=$sizePx'
        'y$sizePx$fragment';
  }
  // Not an http(s) URL: keep local covers, drop everything else.
  final String trimmed = raw?.trim() ?? '';
  return trimmed.startsWith('file://') ? trimmed : null;
}

/// Cover requests carry the app identity and music-site Referer. CDN nodes
/// can still reject an individual request; callers use bounded alternatives.
const Map<String, String> artworkHeaders = <String, String>{
  'User-Agent': 'LazerDesktop/1.0',
  'Referer': 'https://music.163.com/',
};

/// Ordered alternatives for an intermittently rejected NetEase CDN image.
/// Only known image CDN hosts are rewritten; the artwork path is preserved.
List<String> artworkCandidates(String? raw) {
  final preferred = enlargedArtworkUrl(raw);
  if (preferred == null) return const <String>[];
  final uri = Uri.tryParse(preferred);
  if (uri == null || !RegExp(r'^p[1-4]\.music\.126\.net$').hasMatch(uri.host)) {
    return <String>[preferred];
  }
  final query = Map<String, String>.of(uri.queryParameters)..remove('param');
  final original = uri.replace(
    queryParameters: query.isEmpty ? null : query,
    query: query.isEmpty ? '' : null,
  );
  return <String>{
    preferred,
    original.toString(),
    for (final host in const <String>[
      'p2.music.126.net',
      'p3.music.126.net',
      'p4.music.126.net',
      'p1.music.126.net',
    ])
      original.replace(host: host).toString(),
  }.toList(growable: false);
}
