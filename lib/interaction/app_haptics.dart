import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Semantic actions only. Each UI control calls this after recognizing a tap.
class AppHaptics {
  AppHaptics({DateTime Function()? now}) : _now = now ?? DateTime.now;
  static const channel = MethodChannel('dev.naominet.lazer/haptics');
  final DateTime Function() _now;
  DateTime? _last;

  Future<void> pulse({
    required bool enabled,
    required double intensity,
    bool detent = false,
    bool boundary = false,
  }) async {
    if (!enabled || intensity <= 0 || kIsWeb) return;
    final platform = defaultTargetPlatform;
    if (platform != TargetPlatform.iOS && platform != TargetPlatform.android) {
      return;
    }
    final now = _now();
    if (_last != null &&
        now.difference(_last!) < Duration(milliseconds: detent ? 35 : 60)) {
      return;
    }
    _last = now;
    try {
      if (platform == TargetPlatform.iOS) {
        await channel.invokeMethod<void>('impact', {
          'intensity': (intensity * (detent && !boundary ? .55 : 1)).clamp(
            0.0,
            1.0,
          ),
          'kind': boundary
              ? 'boundary'
              : detent
              ? 'detent'
              : 'tap',
        });
      } else {
        await HapticFeedback.selectionClick();
      }
    } on MissingPluginException {
      // Also supports hosts where the native haptics channel is unavailable.
      await HapticFeedback.lightImpact();
    } on PlatformException {
      // Device haptics are optional and must never prevent an action.
    }
  }
}

/// Quantized seek feedback: repeat ticks require movement to another notch,
/// so a held thumb or a 100 ms playback update cannot keep vibrating.
class SeekDetents {
  int? _notch;
  bool active = false;
  void begin(double value) {
    active = true;
    _notch = (value.clamp(0, 1) * 100).round();
  }

  bool update(double value) {
    if (!active) return false;
    final next = (value.clamp(0, 1) * 100).round();
    if (next == _notch) return false;
    _notch = next;
    return true;
  }

  void end() {
    active = false;
    _notch = null;
  }
}
