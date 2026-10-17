import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:math' as math;

import 'crypto.dart';
import 'routes.dart';

/// HTTP failure before a valid API response could be decoded. The upstream
/// body is never retained.
class GatewayHttpException implements Exception {
  GatewayHttpException(this.statusCode, this.endpoint);

  final int statusCode;
  final String endpoint;

  @override
  String toString() =>
      'Gateway request to $endpoint failed with HTTP $statusCode.';
}

/// Successful HTTP response that was not valid JSON.
class GatewayProtocolException implements Exception {
  GatewayProtocolException(
    this.endpoint, [
    this.detail = 'Invalid upstream JSON.',
  ]);

  final String endpoint;
  final String detail;

  @override
  String toString() => 'Gateway request to $endpoint returned malformed JSON.';
}

class GatewayServiceException implements Exception {
  GatewayServiceException(this.code, this.endpoint);
  final int code;
  final String endpoint;
  @override
  String toString() => 'Gateway request to $endpoint was rejected ($code).';
}

/// Cookies that make up a gateway session. The device/anonymous identifiers
/// are kept because the QR flow hands the confirmed session back through them:
/// `/login/qr/check` answers 803 with `MUSIC_U` plus whichever of these the
/// server rotated while the phone confirmed, and every later request has to
/// replay that exact set — api-enhanced passes the whole jar through the same
/// way (`cookieToJson` has no whitelist).
const Set<String> _sessionNames = <String>{
  'MUSIC_U',
  'MUSIC_A',
  'NMTID',
  'deviceId',
  'sDeviceId',
  '__csrf',
  // Older responses carry the CSRF value under this alias; api-enhanced's
  // cookie jar keeps it, and weapi requests read it when `__csrf` is missing.
  '__csrf_token',
  '_ntes_nuid',
  '_ntes_nnid',
  'WNMCID',
  'WEVNSM',
};

const Set<String> _cookieAttributeNames = <String>{
  'domain',
  'expires',
  'httponly',
  'max-age',
  'partitioned',
  'path',
  'priority',
  'sameparty',
  'samesite',
  'secure',
};

final RegExp _cookieNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Converts a Cookie header or a flattened Set-Cookie response into a compact
/// Cookie header. Last value wins for a repeated name.
String? normalizeGatewaySessionCookie(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final Map<String, String> cookies = <String, String>{};
  final input = value
      .trim()
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceFirst(RegExp(r'^cookie:\s*', caseSensitive: false), '');
  for (final String rawSegment in input.split(';')) {
    String segment = rawSegment.trim();
    if (segment.startsWith('Set-Cookie:')) {
      segment = segment.substring('Set-Cookie:'.length).trim();
    }
    if (segment.startsWith('set-cookie:')) {
      segment = segment.substring('set-cookie:'.length).trim();
    }
    final int separator = segment.indexOf('=');
    if (separator <= 0) continue;
    final String name = segment.substring(0, separator).trim();
    final String cookieValue = segment.substring(separator + 1).trim();
    if (!_cookieNamePattern.hasMatch(name)) continue;
    if (_cookieAttributeNames.contains(name.toLowerCase())) continue;
    if (!_sessionNames.contains(name)) continue;
    if (cookieValue.contains('\r') || cookieValue.contains('\n')) continue;
    cookies[name] = cookieValue;
  }
  if (cookies.isEmpty) return null;
  return cookies.entries
      .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
      .join('; ');
}

const Set<String> _transportOverrides = <String>{
  'cookie',
  'domain',
  'crypto',
  'proxy',
  'headers',
  'realIP',
  'randomCNIP',
  'ua',
  'checkToken',
  'e_r',
};

/// Port of NeteaseTransport.kt: weapi/eapi POST transport, session cookies,
/// and the response envelopes the Kotlin wrapper synthesizes in-process.
class NeteaseTransport {
  NeteaseTransport({
    this.userAgent = 'Lazer',
    this.requestTimeout = const Duration(seconds: 30),
    io.HttpClient? client,
    DateTime Function()? clock,
  }) : _client =
           client ?? (io.HttpClient()..connectionTimeout = requestTimeout),
       _clock = clock ?? DateTime.now;

  final String userAgent;
  final Duration requestTimeout;
  final io.HttpClient _client;
  final DateTime Function() _clock;

  String? cookie;

  Future<Map<String, dynamic>> request(
    String alias,
    Map<String, String> parameters,
  ) async {
    if (!alias.startsWith('/') ||
        alias.startsWith('//') ||
        alias.contains('?') ||
        alias.contains('#') ||
        alias.contains(r'\') ||
        alias.contains(':') ||
        alias.contains('..')) {
      throw ArgumentError.value(
        alias,
        'alias',
        'Supply a supported relative Gateway route.',
      );
    }
    if (parameters.keys.any(_transportOverrides.contains)) {
      throw ArgumentError(
        'Built-in Gateway transport overrides are not supported.',
      );
    }
    if (alias == '/login/qr/create') {
      final String key = parameters['key'] ?? '';
      if (key.trim().isEmpty) throw ArgumentError('key cannot be blank.');
      final String qrUrl = _qrLoginUrl(key, parameters['platform'] ?? 'pc');
      return <String, dynamic>{
        'code': 200,
        'data': <String, dynamic>{'qrurl': qrUrl, 'qrimg': ''},
      };
    }
    if (alias == '/playlist/track/all') return _playlistTracks(parameters);
    final NeteaseRequest route = buildNeteaseRequest(alias, parameters);
    late final _Response result;
    try {
      result = await _execute(route, alias);
    } on GatewayProtocolException {
      // These public weapi endpoints currently sometimes return HTTP 200
      // with an empty body. Their ordinary HTTPS API equivalents carry the
      // same response schema and keep discovery and playback available.
      if (alias == '/song/detail') {
        result = await _executePublicPost(route, alias);
      } else if (const <String>{
        '/top/playlist',
        '/song/url/v1',
        '/login/status',
        '/user/playlist',
        '/recommend/songs',
        '/recommend/resource',
        '/personal_fm',
        '/album',
        '/artist/top/song',
        '/user/detail',
      }.contains(alias)) {
        result = await _executePublicGet(route, alias);
      } else {
        rethrow;
      }
    }
    final Map<String, dynamic> body = result.body;
    switch (alias) {
      case '/login/qr/key':
        // The unikey response seeds the QR session (NMTID/__csrf/sDeviceId).
        // Every later /check poll must carry this cookie or the server treats
        // each poll as a fresh anonymous visitor and never reports 803.
        return <String, dynamic>{
          'code': 200,
          'data': body,
          if (result.cookie != null) 'cookie': result.cookie,
        };
      case '/login/status':
        return <String, dynamic>{'data': body};
      case '/login':
      case '/login/cellphone':
      case '/login/refresh':
        final bool successful = body['code'] == 200;
        if (successful && result.cookie != null) {
          return <String, dynamic>{...body, 'cookie': result.cookie};
        }
        return body;
      case '/login/qr/check':
        // api-enhanced forwards the response cookie on every poll code
        // (801/802 included), not just on 803: the session rotates while the
        // user scans and the next poll has to present the newest cookie.
        if (result.cookie != null) {
          return <String, dynamic>{...body, 'cookie': result.cookie};
        }
        return body;
      case '/check/music':
        final dynamic first =
            body['data'] is List && (body['data'] as List).isNotEmpty
            ? (body['data'] as List).first
            : null;
        final bool available =
            body['code'] == 200 &&
            first is Map<String, dynamic> &&
            first['code'] == 200;
        return <String, dynamic>{
          'code': 200,
          'success': available,
          'message': available ? 'ok' : '暂无版权',
        };
      default:
        if (body['code'] is int && body['code'] != 200) {
          throw GatewayServiceException(body['code'] as int, alias);
        }
        return body;
    }
  }

  Future<Map<String, dynamic>> _playlistTracks(
    Map<String, String> parameters,
  ) async {
    final int offset = int.tryParse(parameters['offset'] ?? '') ?? 0;
    final int limit = int.tryParse(parameters['limit'] ?? '') ?? 1000;
    if (offset < 0 || limit <= 0) throw ArgumentError('Invalid playlist page.');
    final Map<String, dynamic> detail = (await _execute(
      buildNeteaseRequest('/playlist/detail', parameters),
      '/playlist/track/all',
    )).body;
    if (detail['code'] != 200) return detail;
    final dynamic playlist = detail['playlist'];
    final dynamic trackIds = playlist is Map<String, dynamic>
        ? playlist['trackIds']
        : null;
    if (trackIds is! List) {
      throw GatewayProtocolException(
        '/playlist/track/all',
        'Missing track IDs.',
      );
    }
    final List<dynamic> page = trackIds.skip(offset).take(limit).toList();
    if (page.isEmpty) {
      return <String, dynamic>{
        'code': 200,
        'songs': <dynamic>[],
        'privileges': <dynamic>[],
      };
    }
    final List<Map<String, Object?>> payload = page.map<Map<String, Object?>>((
      dynamic track,
    ) {
      final dynamic id = track is Map<String, dynamic> ? track['id'] : null;
      final int? songId = id is int
          ? id
          : (id is String ? int.tryParse(id) : null);
      if (songId == null || songId <= 0) {
        throw ArgumentError('Invalid playlist track ID.');
      }
      return <String, Object?>{'id': songId};
    }).toList();
    final _Response songs = await _execute(
      NeteaseRequest(
        path: '/api/v3/song/detail',
        payload: <String, Object?>{'c': jsonEncode(payload)},
        encoding: NeteaseEncoding.weapi,
      ),
      '/playlist/track/all',
    );
    return songs.body;
  }

  Future<_Response> _execute(NeteaseRequest route, String alias) async {
    final String? currentCookie = cookie;
    final Map<String, String> cookies = <String, String>{};
    for (final String segment in (currentCookie ?? '').split(';')) {
      final int separator = segment.indexOf('=');
      if (separator > 0) {
        cookies[segment.substring(0, separator).trim()] = segment
            .substring(separator + 1)
            .trim();
      }
    }
    // The QR confirmation can hand the CSRF value back under either name;
    // api-enhanced accepts both and so do the upstream weapi endpoints.
    final String csrf =
        cookies['__csrf'] ?? cookies['__csrf_token'] ?? '';
    final bool web = route.encoding == NeteaseEncoding.weapi;
    final Map<String, Object?> payload = <String, Object?>{
      ...route.payload,
      'e_r': false,
    };
    if (web) {
      payload['csrf_token'] = csrf;
    } else {
      payload['header'] = <String, Object?>{
        'os': route.mobileClient ? 'android' : 'pc',
        'appver': route.mobileClient ? '9.5.95' : '3.1.17.204416',
        if (route.mobileClient) 'versioncode': '9005095',
        '__csrf': csrf,
        'requestId':
            '${_clock().millisecondsSinceEpoch}_${gatewayHexLower(_secureRandom(4))}',
        for (final String name in const <String>[
          'MUSIC_U',
          'MUSIC_A',
          'NMTID',
          'deviceId',
        ])
          if (cookies[name] != null) name: cookies[name],
      };
    }
    final Map<String, String> form = web
        ? gatewayWeapi(jsonEncode(payload))
        : <String, String>{
            'params': gatewayEapi(route.path, jsonEncode(payload)),
          };
    final String endpoint = web
        ? 'https://music.163.com/weapi/'
        : 'https://interfacepc.music.163.com/eapi/';
    final String upstreamPath = route.path.startsWith('/api/')
        ? route.path.substring(5)
        : route.path;
    final io.HttpClientRequest request = await _client
        .postUrl(Uri.parse('$endpoint$upstreamPath'))
        .timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.set(io.HttpHeaders.cacheControlHeader, 'no-cache');
    final String? requestCookie = route.mobileClient
        ? <String>[
            ?currentCookie,
            'os=android',
            'appver=9.5.95',
            'versioncode=9005095',
          ].join('; ')
        : currentCookie;
    if (requestCookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, requestCookie);
    }
    request.headers.contentType = io.ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(
      form.entries
          .map(
            (MapEntry<String, String> e) =>
                '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
    );
    final io.HttpClientResponse response = await request.close().timeout(
      requestTimeout,
    );
    final String bodyText = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayHttpException(response.statusCode, alias);
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(bodyText);
    } on FormatException {
      throw GatewayProtocolException(alias);
    }
    if (decoded is! Map<String, dynamic>) throw GatewayProtocolException(alias);
    final Map<String, dynamic> normalizedBody = _normalizeFields(decoded);
    final dynamic rawCode = normalizedBody['code'];
    final Map<String, dynamic> normalized = rawCode is num
        ? <String, dynamic>{...normalizedBody, 'code': rawCode.toInt()}
        : (rawCode is String && int.tryParse(rawCode) != null
              ? <String, dynamic>{...normalizedBody, 'code': int.parse(rawCode)}
              : normalizedBody);
    final List<String> setCookies = <String>[];
    response.headers.forEach((String name, List<String> values) {
      if (name == 'set-cookie') setCookies.addAll(values);
    });
    final String? mergedCookie = setCookies.isEmpty
        ? null
        : normalizeGatewaySessionCookie(
            <String>[
              ?currentCookie,
              for (final String setCookie in setCookies)
                setCookie.split(';').first,
            ].join('; '),
          );
    return _Response(normalized, mergedCookie);
  }

  Future<_Response> _executePublicGet(
    NeteaseRequest route,
    String alias,
  ) async {
    final Uri uri = Uri.https(
      'music.163.com',
      route.path,
      route.payload.map((key, value) => MapEntry(key, value.toString())),
    );
    final request = await _client.getUrl(uri).timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    request.headers.set('Referer', 'https://music.163.com/');
    if (cookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, cookie!);
    }
    final response = await request.close().timeout(requestTimeout);
    return _decodePublicResponse(response, alias);
  }

  Future<_Response> _executePublicPost(
    NeteaseRequest route,
    String alias,
  ) async {
    final Uri uri = Uri.https('music.163.com', route.path);
    final request = await _client.postUrl(uri).timeout(requestTimeout);
    request.headers.set(io.HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(io.HttpHeaders.userAgentHeader, userAgent);
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.contentType = io.ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    if (cookie != null) {
      request.headers.set(io.HttpHeaders.cookieHeader, cookie!);
    }
    request.write(
      route.payload.entries
          .map(
            (entry) =>
                '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value.toString())}',
          )
          .join('&'),
    );
    final response = await request.close().timeout(requestTimeout);
    return _decodePublicResponse(response, alias);
  }

  Future<_Response> _decodePublicResponse(
    io.HttpClientResponse response,
    String alias,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw GatewayHttpException(response.statusCode, alias);
    }
    final bodyText = await response.transform(utf8.decoder).join();
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      return _Response(_normalizeFields(decoded), null);
    } on FormatException {
      throw GatewayProtocolException(alias);
    }
  }

  static Map<String, dynamic> _normalizeFields(Map<String, dynamic> element) {
    return element.map((String key, dynamic value) {
      final String name = key == 'avatarImgId_str' ? 'avatarImgIdStr' : key;
      if (value is Map<String, dynamic>) {
        return MapEntry<String, dynamic>(name, _normalizeFields(value));
      }
      if (value is List) {
        return MapEntry<String, dynamic>(
          name,
          value
              .map<dynamic>(
                (dynamic item) => item is Map<String, dynamic>
                    ? _normalizeFields(item)
                    : item,
              )
              .toList(),
        );
      }
      return MapEntry<String, dynamic>(name, value);
    });
  }

  static List<int> _secureRandom(int size) {
    return List<int>.generate(size, (_) => _rng.nextInt(256));
  }

  /// RFC 4122 version 4 id from the secure RNG.
  static String _uuidV4() {
    final List<int> bytes = _secureRandom(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final String hex = bytes
        .map((int b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Scan URL for the QR login.
  ///
  /// The base form is `https://music.163.com/login?codekey=<unikey>`; the
  /// phone app (9.6.x) recognises exactly that path and reads a
  /// `login_traceId` query parameter on the way, which it forwards as
  /// `clientTraceId` when it confirms the scan through
  /// `login/qrcode/server/login`. Without that trace the confirmation has
  /// nothing to bind back to this scan session, the key never reaches 803 and
  /// the desktop keeps polling a scan the server cannot see. Every QR we mint
  /// therefore carries its own trace, and the poll replays it.
  ///
  /// The `web` platform additionally expects a `chainId`
  /// (`v1_{sDeviceId}_{platform}_{action}_{timestamp}`), but only one derived
  /// from a **real** `sDeviceId`: a made-up `unknown-…` device id names a
  /// session the phone cannot resolve. Only append it when the id is real,
  /// never fabricate one.
  String _qrLoginUrl(String key, String platform) {
    final StringBuffer url = StringBuffer(
      'https://music.163.com/login?codekey=${Uri.encodeQueryComponent(key)}',
    );
    url.write('&login_traceId=${Uri.encodeQueryComponent(_uuidV4())}');
    if (platform == 'web') {
      final String deviceId = _cookieValue(cookie, 'sDeviceId');
      if (deviceId.isNotEmpty) {
        final String chainId =
            'v1_${deviceId}_web_login_${_clock().millisecondsSinceEpoch}';
        url.write('&chainId=${Uri.encodeQueryComponent(chainId)}');
      }
    }
    return url.toString();
  }

  /// Reads a single cookie value out of a `Cookie` header, or ''.
  static String _cookieValue(String? header, String name) {
    for (final String segment in (header ?? '').split(';')) {
      final int separator = segment.indexOf('=');
      if (separator <= 0) continue;
      if (segment.substring(0, separator).trim() == name) {
        return segment.substring(separator + 1).trim();
      }
    }
    return '';
  }

  static final math.Random _rng = math.Random.secure();
}

class _Response {
  const _Response(this.body, this.cookie);

  final Map<String, dynamic> body;
  final String? cookie;
}
