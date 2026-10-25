import 'dart:io';

import 'package:flutter/services.dart';

/// Android's audio-read permission. Everywhere else scanning needs no runtime
/// grant (the macOS sandbox grant lives in the entitlements file).
class LocalMediaPermission {
  const LocalMediaPermission();

  static const MethodChannel _channel = MethodChannel(
    'dev.naominet.lazer/local_media',
  );

  Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('hasAudioAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> requestAccess() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestAudioAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
