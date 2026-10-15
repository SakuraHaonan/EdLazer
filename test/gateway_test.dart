import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/gateway/crypto.dart';
import 'package:lazer_nextgen/gateway/routes.dart';
import 'package:lazer_nextgen/gateway/transport.dart';

void main() {
  test('recommended playlist route matches api-enhanced weapi payload', () {
    final route = buildNeteaseRequest('/personalized', {'limit': '12'});
    expect(route.path, '/api/personalized/playlist');
    expect(route.encoding, NeteaseEncoding.weapi);
    expect(route.payload, {'limit': '12', 'total': true, 'n': 1000});
  });
  group('gatewayMd5', () {
    test('matches the standard vector', () {
      expect(gatewayMd5('hello'), '5d41402abc4b2a76b9719d911017c592');
      expect(gatewayMd5(''), 'd41d8cd98f00b204e9800998ecf8427e');
    });
  });

  group('gatewayWeapi', () {
    test('round-trips through both AES layers with a fixed secret', () {
      const String json = '{"s":"field notes","e_r":false}';
      final Map<String, String> form = gatewayWeapi(
        json,
        secret: 'abcdefghijklmnop',
      );
      expect(
        form['params'],
        'HAN+tvENK8H64oQcDLa2ba85QCsOmKfN8b681FgUu4zpOZWPb06WOC/aKMd2RbTA',
        reason: 'independent Node crypto AES-CBC vector',
      );
      expect(form.keys, <String>['params', 'encSecKey']);
      expect(form['encSecKey'], hasLength(256));
      final String first = gatewayAesCbcDecrypt(
        base64Decode(form['params']!),
        'abcdefghijklmnop',
      );
      final String original = gatewayAesCbcDecrypt(
        base64Decode(first),
        '0CoJUm6Qyw8W8jud',
      );
      expect(original, json);
    });

    test('is deterministic for a fixed secret', () {
      final Map<String, String> a = gatewayWeapi(
        '{}',
        secret: '0123456789abcdef',
      );
      final Map<String, String> b = gatewayWeapi(
        '{}',
        secret: '0123456789abcdef',
      );
      expect(a, b);
    });

    test('rejects a malformed secret', () {
      expect(() => gatewayWeapi('{}', secret: 'short'), throwsArgumentError);
      expect(
        () => gatewayWeapi('{}', secret: 'abcdefghijklmno-'),
        throwsArgumentError,
      );
    });
  });

  group('gatewayEapi', () {
    test('round-trips the path/json/md5 envelope', () {
      const String path = '/api/song/lyric';
      const String json = '{"id":123}';
      final String hex = gatewayEapi(path, json);
      expect(hex, equals(hex.toUpperCase()));
      final String payload = gatewayAesEcbDecrypt(
        _hexToBytes(hex),
        'e82ckenh8dichen8',
      );
      final String digest = gatewayMd5('nobody${path}use${json}md5forencrypt');
      expect(payload, '$path-36cd479b6b5-$json-36cd479b6b5-$digest');
    });
  });

  group('normalizeGatewaySessionCookie', () {
    test('accepts pasted header prefixes and preserves equals in values', () {
      expect(
        normalizeGatewaySessionCookie(
          '\uFEFFCookie: MUSIC_U=abc==; __csrf=token',
        ),
        'MUSIC_U=abc==; __csrf=token',
      );
    });
    test('drops Set-Cookie attributes and keeps the last value', () {
      final String? normalized = normalizeGatewaySessionCookie(
        'MUSIC_U=abc; Path=/; Domain=.music.163.com; __csrf=token123; '
        'MUSIC_U=final; Max-Age=0; Secure',
      );
      expect(normalized, 'MUSIC_U=final; __csrf=token123');
    });

    test('strips a Set-Cookie prefix and rejects malformed names', () {
      expect(
        normalizeGatewaySessionCookie('Set-Cookie: NMTID=nv; HttpOnly'),
        'NMTID=nv',
      );
      expect(normalizeGatewaySessionCookie('bad name=value'), isNull);
      expect(normalizeGatewaySessionCookie('=novalue'), isNull);
      expect(normalizeGatewaySessionCookie(null), isNull);
      expect(normalizeGatewaySessionCookie('   '), isNull);
    });
  });

  group('buildNeteaseRequest', () {
    test('maps search onto /api/search/get', () {
      final NeteaseRequest request = buildNeteaseRequest(
        '/search',
        <String, String>{
          'keywords': 'nocturne',
          'type': '1',
          'limit': '30',
          'offset': '0',
        },
      );
      expect(request.path, '/api/search/get');
      expect(request.encoding, NeteaseEncoding.eapi);
      expect(request.payload['s'], 'nocturne');
      expect(request.payload['type'], '1');
      expect(request.payload['limit'], '30');
    });

    test('maps song url onto the web player url route', () {
      final NeteaseRequest request = buildNeteaseRequest(
        '/song/url/v1',
        <String, String>{'id': '42', 'level': 'standard'},
      );
      expect(request.path, '/api/song/enhance/player/url');
      expect(request.encoding, NeteaseEncoding.weapi);
      expect(request.payload['ids'], '[42]');
      expect(request.payload['br'], 128000);
    });

    test('maps comments and listen-together onto finite service routes', () {
      final comments = buildNeteaseRequest(
        '/comment/music',
        const <String, String>{'id': '42'},
      );
      expect(comments.path, '/api/v1/resource/comments/R_SO_4_42');
      final room = buildNeteaseRequest(
        '/listentogether/room/check',
        const <String, String>{'roomId': 'room_42'},
      );
      expect(room.mobileClient, isTrue);
      expect(room.payload['roomId'], 'room_42');
      expect(
        () => buildNeteaseRequest(
          '/listentogether/room/check',
          const <String, String>{'roomId': '../escape'},
        ),
        throwsArgumentError,
      );
    });

    test('rejects unsupported aliases and bad ids', () {
      expect(
        () => buildNeteaseRequest('/unknown', const <String, String>{}),
        throwsArgumentError,
      );
      expect(
        () => buildNeteaseRequest('/lyric', const <String, String>{'id': '0'}),
        throwsArgumentError,
      );
      expect(
        () =>
            buildNeteaseRequest('/lyric', const <String, String>{'id': 'abc'}),
        throwsArgumentError,
      );
    });
  });

  group('synthetic qr create', () {
    test('builds the scan URL locally without a network call', () async {
      final NeteaseTransport transport = NeteaseTransport();
      final Map<String, dynamic> body = await transport.request(
        '/login/qr/create',
        <String, String>{'key': 'abc123'},
      );
      expect(body['code'], 200);
      final Map<String, dynamic> data = body['data'] as Map<String, dynamic>;
      expect(data['qrurl'], 'https://music.163.com/login?codekey=abc123');
    });

    test('refuses a blank key', () async {
      final NeteaseTransport transport = NeteaseTransport();
      await expectLater(
        transport.request('/login/qr/create', <String, String>{'key': ''}),
        throwsArgumentError,
      );
    });
  });
}

List<int> _hexToBytes(String hex) {
  final List<int> bytes = <int>[];
  for (int i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}
