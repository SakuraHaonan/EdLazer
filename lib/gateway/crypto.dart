import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:encrypt/encrypt.dart' as enc;

/// Port of `shared/.../gateway/NeteaseCrypto.kt` (+ the JVM actuals).
///
/// The protocol encoding is obfuscation only; HTTPS provides transport
/// security. Everything here is deterministic given a [secret] so tests can
/// pin vectors without a network.
enum NeteaseEncoding { eapi, weapi }

const String _weapiFirstKey = '0CoJUm6Qyw8W8jud';
const String _eapiKey = 'e82ckenh8dichen8';
const String _weapiAlphabet =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const String _modulusHex =
    'e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b72515'
    '2b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec'
    'bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8'
    '13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7';

final BigInt _rsaModulus = BigInt.parse(_modulusHex, radix: 16);

String gatewayMd5(String value) =>
    c.md5.convert(utf8.encode(value)).toString().toLowerCase();

/// Lowercase hex, the form the weapi paths use.
String gatewayHexLower(List<int> bytes) =>
    bytes.map((int b) => (b & 0xff).toRadixString(16).padLeft(2, '0')).join();

/// Uppercase hex, matching Kotlin's `.hex()` for the eapi envelope.
String gatewayHexUpper(List<int> bytes) => bytes
    .map((int b) => (b & 0xff).toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

Uint8List _aesEcb(List<int> data, List<int> key) => Uint8List.fromList(
  enc.Encrypter(
    enc.AES(
      enc.Key(Uint8List.fromList(key)),
      mode: enc.AESMode.ecb,
      padding: 'PKCS7',
    ),
  ).encryptBytes(data).bytes,
);

Uint8List _aesCbc(List<int> data, List<int> key, List<int> iv) =>
    Uint8List.fromList(
      enc.Encrypter(
        enc.AES(
          enc.Key(Uint8List.fromList(key)),
          mode: enc.AESMode.cbc,
          padding: 'PKCS7',
        ),
      ).encryptBytes(data, iv: enc.IV(Uint8List.fromList(iv))).bytes,
    );

/// Exposed for tests: reverses the EAPI AES-ECB envelope.
String gatewayAesEcbDecrypt(List<int> data, String key) => utf8.decode(
  enc.Encrypter(
    enc.AES(enc.Key.fromUtf8(key), mode: enc.AESMode.ecb, padding: 'PKCS7'),
  ).decryptBytes(enc.Encrypted(Uint8List.fromList(data))),
);

/// Exposed for tests: reverses either of [gatewayWeapi]'s AES-CBC layers.
String gatewayAesCbcDecrypt(List<int> data, String key) => utf8.decode(
  enc.Encrypter(
    enc.AES(enc.Key.fromUtf8(key), mode: enc.AESMode.cbc, padding: 'PKCS7'),
  ).decryptBytes(
    enc.Encrypted(Uint8List.fromList(data)),
    iv: enc.IV.fromUtf8('0102030405060708'),
  ),
);

/// Raw RSA with the fixed public modulus and exponent 65537, matching
/// `rsaEncode` in NeteaseCrypto.kt.
String gatewayRsaEncode(List<int> input) {
  final BigInt base = BigInt.parse(gatewayHexUpper(input), radix: 16);
  BigInt result = base;
  for (int i = 0; i < 16; i++) {
    result = (result * result) % _rsaModulus;
  }
  result = (result * base) % _rsaModulus;
  return result.toRadixString(16).padLeft(256, '0').toUpperCase();
}

String _randomWeapiSecret() {
  final Random rng = Random.secure();
  final StringBuffer buffer = StringBuffer();
  while (buffer.length < 16) {
    for (int i = 0; i < 32; i++) {
      if (buffer.length >= 16) break;
      final int value = rng.nextInt(256);
      if (value < 248) {
        buffer.write(_weapiAlphabet[value % _weapiAlphabet.length]);
      }
    }
  }
  return buffer.toString();
}

/// weapi form body: double AES-CBC of the JSON plus the RSA'd secret.
Map<String, String> gatewayWeapi(String json, {String? secret}) {
  final String key = secret ?? _randomWeapiSecret();
  if (key.length != 16 || !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(key)) {
    throw ArgumentError.value(key, 'secret', 'must be 16 alphanumeric chars');
  }
  final String first = base64Encode(
    _aesCbc(
      utf8.encode(json),
      utf8.encode(_weapiFirstKey),
      utf8.encode('0102030405060708'),
    ),
  );
  final String second = base64Encode(
    _aesCbc(
      utf8.encode(first),
      utf8.encode(key),
      utf8.encode('0102030405060708'),
    ),
  );
  final String reversed = key.split('').reversed.join();
  return <String, String>{
    'params': second,
    'encSecKey': gatewayRsaEncode(utf8.encode(reversed)),
  };
}

/// eapi envelope: AES-ECB of `path-36cd479b6b5-json-36cd479b6b5-md5`,
/// returned as uppercase hex.
String gatewayEapi(String path, String json) {
  final String digest = gatewayMd5('nobody${path}use${json}md5forencrypt');
  final String payload = '$path-36cd479b6b5-$json-36cd479b6b5-$digest';
  return gatewayHexUpper(_aesEcb(utf8.encode(payload), utf8.encode(_eapiKey)));
}
