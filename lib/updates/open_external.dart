import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel _updatesChannel = MethodChannel(
  'org.haonan.edlazer/updates',
);

/// Opens an http(s) link in the system browser.
///
/// The app deliberately carries no `url_launcher` dependency: desktop shells
/// can hand the URL to the platform directly, and Android/iOS answer through
/// the same channel the TV and haptics bridges already use. Only http and
/// https are accepted, so a malformed release payload cannot ask the platform
/// to start an arbitrary scheme.
///
/// Returns false when no browser could be launched; callers then show the URL
/// itself instead of failing silently.
Future<bool> openExternalUrl(String raw) async {
  final Uri? uri = Uri.tryParse(raw.trim());
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
    return false;
  }
  if (kIsWeb) return false;
  if (defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      return await _updatesChannel.invokeMethod<bool>(
            'openUrl',
            <String, Object>{'url': uri.toString()},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }
  try {
    final Process process;
    if (Platform.isWindows) {
      process = await Process.start('rundll32', <String>[
        'url.dll,FileProtocolHandler',
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      process = await Process.start('open', <String>[
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      process = await Process.start('xdg-open', <String>[
        uri.toString(),
      ], mode: ProcessStartMode.detached);
    } else {
      return false;
    }
    process.exitCode.ignore();
    return true;
  } catch (_) {
    return false;
  }
}
