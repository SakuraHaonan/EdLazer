import 'dart:convert';

import 'package:http/http.dart' as http;

/// Resolves Apple Music's animated album artwork - the HLS video Apple ships
/// for albums that have a moving cover.
///
/// Apple authorises its private catalogue API with a developer token that is
/// baked into the public web bundle, so this needs no account and no app
/// secret. Everything here is best-effort: every failure path returns null and
/// the caller keeps the static cover.
class AppleMotionArtwork {
  AppleMotionArtwork({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Album key -> manifest (null means "checked, has none").
  final Map<String, String?> _manifests = <String, String?>{};

  static String? _token;
  static bool _tokenDead = false;

  static const String _webHost = 'https://music.apple.com';
  static const String _catalogHost = 'https://amp-api.music.apple.com';

  /// Apple answers a default Dart user agent with a stripped page, so the
  /// bundle reference never shows up. The scrape needs a browser-shaped
  /// request.
  static const Map<String, String> _browserHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
  };

  /// The HLS manifest for [album] by [artist], or null when Apple has no
  /// animated cover for it (or the lookup could not be completed).
  Future<String?> manifestFor({
    required String artist,
    required String album,
  }) async {
    if (artist.trim().isEmpty || album.trim().isEmpty) return null;
    final String key =
        '${artist.trim().toLowerCase()}|${album.trim().toLowerCase()}';
    if (_manifests.containsKey(key)) return _manifests[key];
    final String? found = await _resolve(artist.trim(), album.trim());
    _manifests[key] = found;
    return found;
  }

  Future<String?> _resolve(String artist, String album) async {
    try {
      final _AppleAlbum? match = await _searchAlbum(artist, album);
      if (match == null) return null;
      final String? token = await _authToken(match.pageUrl);
      if (token == null) return null;
      return await _editorialVideo(match.id, token, match.storefront);
    } catch (_) {
      return null;
    }
  }

  /// Public iTunes search - no authorisation involved.
  Future<_AppleAlbum?> _searchAlbum(String artist, String album) async {
    final Uri uri = Uri.https('itunes.apple.com', '/search', <String, String>{
      'term': '$artist $album',
      'entity': 'album',
      'limit': '8',
      'country': 'us',
    });
    final http.Response res = await _client.get(uri);
    if (res.statusCode != 200) return null;
    final Map<String, dynamic> body =
        jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> results =
        (body['results'] as List<dynamic>?) ?? const <dynamic>[];
    if (results.isEmpty) return null;

    final String wanted = _normalize(album);
    Map<String, dynamic>? exact;
    for (final dynamic raw in results) {
      if (raw is Map<String, dynamic> &&
          _normalize('${raw['collectionName']}') == wanted) {
        exact = raw;
        break;
      }
    }
    final Map<String, dynamic> pick =
        exact ?? results.first as Map<String, dynamic>;
    final int? id = (pick['collectionId'] as num?)?.toInt();
    if (id == null || id <= 0) return null;
    final String page =
        '${pick['collectionViewUrl'] ?? '$_webHost/us/album/$id'}';
    return _AppleAlbum(
      id: id,
      pageUrl: page.contains('/album/') ? page : '$_webHost/us/album/$id',
      storefront: _storefrontOf(page),
    );
  }

  /// Scrapes the developer token out of the web player's JS bundle. Apple
  /// rotates it, so it is cached only for this run and re-read on a 401.
  Future<String?> _authToken(String albumPageUrl) async {
    final String? cached = _token;
    if (cached != null) return cached;
    if (_tokenDead) return null;
    try {
      final http.Response page = await _client.get(
        Uri.parse(albumPageUrl),
        headers: _browserHeaders,
      );
      if (page.statusCode != 200) return null;
      final RegExpMatch? src = RegExp(
        r'src="([^"]*(?:/assets/index)[^"]+\.js)"',
      ).firstMatch(page.body);
      if (src == null) return null;
      final String raw = src.group(1)!;
      final http.Response bundle = await _client.get(
        Uri.parse(raw.startsWith('http') ? raw : '$_webHost$raw'),
        headers: _browserHeaders,
      );
      if (bundle.statusCode != 200) return null;

      for (final RegExpMatch match in RegExp(
        r'eyJ[A-Za-z0-9_\-\.]{80,}',
      ).allMatches(bundle.body)) {
        final String candidate = match.group(0)!;
        if (_isWebPlayToken(candidate)) {
          _token = candidate;
          return candidate;
        }
      }
      _tokenDead = true;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The catalogue API only accepts the `WebPlayKid` token; the bundle ships
  /// several unrelated JWTs next to it. The key id lives in the JOSE header
  /// (the first segment), not the payload.
  bool _isWebPlayToken(String jwt) {
    final List<String> parts = jwt.split('.');
    if (parts.length != 3) return false;
    try {
      final String header = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[0])),
      );
      return header.contains('WebPlayKid');
    } catch (_) {
      return false;
    }
  }

  Future<String?> _editorialVideo(
    int albumId,
    String token,
    String storefront,
  ) async {
    final Uri uri = Uri.parse(
      '$_catalogHost/v1/catalog/$storefront/albums/$albumId?extend=editorialVideo',
    );
    final http.Response res = await _client.get(
      uri,
      headers: <String, String>{
        'Authorization': 'Bearer $token',
        'Origin': _webHost,
      },
    );
    if (res.statusCode == 401) {
      _token = null;
      return null;
    }
    if (res.statusCode != 200) return null;

    final Map<String, dynamic> body =
        jsonDecode(res.body) as Map<String, dynamic>;
    final List<dynamic> data =
        (body['data'] as List<dynamic>?) ?? const <dynamic>[];
    if (data.isEmpty) return null;
    final dynamic attributes =
        (data.first as Map<String, dynamic>)['attributes'];
    if (attributes is! Map<String, dynamic>) return null;
    final dynamic video = attributes['editorialVideo'];
    if (video is! Map<String, dynamic>) return null;

    // Square first: the album and player surfaces are square.
    for (final String key in <String>[
      'motionDetailSquare',
      'motionDetailTall',
    ]) {
      final String? url = _findManifest(video[key]);
      if (url != null) return _preferH264(url);
    }
    final String? any = _findManifest(video);
    return any == null ? null : _preferH264(any);
  }

  /// Apple ships the master playlist with both H.264 and HEVC variants. HEVC
  /// needs a separately installed Windows extension, so pin the H.264 variant
  /// instead of letting the OS decoder pick and fail. Falls back to the master
  /// playlist when the manifest cannot be read.
  Future<String?> _preferH264(String manifestUrl) async {
    try {
      final http.Response res = await _client.get(Uri.parse(manifestUrl));
      if (res.statusCode != 200) return manifestUrl;
      final List<String> lines = res.body.split('\n');
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i].trim();
        if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
        if (!line.contains('avc1')) continue;
        for (int j = i + 1; j < lines.length; j++) {
          final String next = lines[j].trim();
          if (next.isEmpty || next.startsWith('#')) continue;
          return next;
        }
      }
      return manifestUrl;
    } catch (_) {
      return manifestUrl;
    }
  }

  String? _findManifest(dynamic node) {
    if (node is String) return node.contains('.m3u8') ? node : null;
    if (node is Map) {
      for (final dynamic value in node.values) {
        final String? found = _findManifest(value);
        if (found != null) return found;
      }
    }
    if (node is List) {
      for (final dynamic value in node) {
        final String? found = _findManifest(value);
        if (found != null) return found;
      }
    }
    return null;
  }

  String _storefrontOf(String url) {
    final RegExpMatch? match = RegExp(
      r'music\.apple\.com/([a-z]{2})/',
    ).firstMatch(url);
    return match?.group(1) ?? 'us';
  }

  String _normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '').trim();
}

class _AppleAlbum {
  const _AppleAlbum({
    required this.id,
    required this.pageUrl,
    required this.storefront,
  });

  final int id;
  final String pageUrl;
  final String storefront;
}
