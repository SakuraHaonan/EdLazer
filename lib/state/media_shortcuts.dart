// i18n:data — action labels and descriptions are translated at their render
// sites with `context.tr`.
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, immutable;
import 'package:flutter/services.dart';

/// A playback action that can be bound to a keyboard combination.
enum MediaShortcutAction {
  playPause,
  previousTrack,
  nextTrack,
  seekBackward,
  seekForward,
  volumeDown,
  volumeUp,
  mute,
}

extension MediaShortcutActionLabels on MediaShortcutAction {
  String get label => switch (this) {
    MediaShortcutAction.playPause => '播放 / 暂停',
    MediaShortcutAction.previousTrack => '上一首',
    MediaShortcutAction.nextTrack => '下一首',
    MediaShortcutAction.seekBackward => '快退 5 秒',
    MediaShortcutAction.seekForward => '快进 5 秒',
    MediaShortcutAction.volumeDown => '减小音量',
    MediaShortcutAction.volumeUp => '增大音量',
    MediaShortcutAction.mute => '静音 / 取消静音',
  };

  String get detail => switch (this) {
    MediaShortcutAction.playPause => '切换当前歌曲的播放状态',
    MediaShortcutAction.previousTrack => '跳到上一首；播放超过 3 秒时从头开始',
    MediaShortcutAction.nextTrack => '跳到下一首',
    MediaShortcutAction.seekBackward => '向后跳转 5 秒',
    MediaShortcutAction.seekForward => '向前跳转 5 秒',
    MediaShortcutAction.volumeDown => '音量降低 5%',
    MediaShortcutAction.volumeUp => '音量提高 5%',
    MediaShortcutAction.mute => '在静音和上次音量之间切换',
  };
}

/// One key plus the exact modifier state required to trigger it.
@immutable
class MediaShortcutBinding {
  const MediaShortcutBinding(
    this.key, {
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  bool get isModifierOnly => isMediaShortcutModifierKey(key);

  /// A human-readable combination, e.g. `Ctrl + Shift + Arrow Right`.
  String get label {
    final bool apple =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final List<String> parts = <String>[
      if (apple && meta) '⌘' else if (meta) 'Meta',
      if (apple && control) '⌃' else if (control) 'Ctrl',
      if (apple && alt) '⌥' else if (alt) 'Alt',
      if (apple && shift) '⇧' else if (shift) 'Shift',
      _keyLabel(key),
    ];
    return parts.join(apple ? ' ' : ' + ');
  }

  /// Stable across launches within the same Flutter engine.
  String encode() =>
      '${key.keyId}|${control ? 1 : 0}|${alt ? 1 : 0}|'
      '${shift ? 1 : 0}|${meta ? 1 : 0}';

  static MediaShortcutBinding? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final List<String> parts = raw.split('|');
    if (parts.length != 5) return null;
    final int? keyId = int.tryParse(parts[0]);
    if (keyId == null) return null;
    return MediaShortcutBinding(
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId),
      control: parts[1] == '1',
      alt: parts[2] == '1',
      shift: parts[3] == '1',
      meta: parts[4] == '1',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaShortcutBinding &&
      other.key == key &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, alt, shift, meta);

  @override
  String toString() => 'MediaShortcutBinding($label)';
}

/// Defaults use Control so they are unlikely to collide with text editing
/// (which is skipped while a text field has focus).
const Map<MediaShortcutAction, MediaShortcutBinding> kDefaultMediaShortcuts =
    <MediaShortcutAction, MediaShortcutBinding>{
      MediaShortcutAction.playPause: MediaShortcutBinding(
        LogicalKeyboardKey.keyP,
        control: true,
      ),
      MediaShortcutAction.previousTrack: MediaShortcutBinding(
        LogicalKeyboardKey.arrowLeft,
        control: true,
      ),
      MediaShortcutAction.nextTrack: MediaShortcutBinding(
        LogicalKeyboardKey.arrowRight,
        control: true,
      ),
      MediaShortcutAction.seekBackward: MediaShortcutBinding(
        LogicalKeyboardKey.arrowLeft,
        control: true,
        shift: true,
      ),
      MediaShortcutAction.seekForward: MediaShortcutBinding(
        LogicalKeyboardKey.arrowRight,
        control: true,
        shift: true,
      ),
      MediaShortcutAction.volumeDown: MediaShortcutBinding(
        LogicalKeyboardKey.arrowDown,
        control: true,
      ),
      MediaShortcutAction.volumeUp: MediaShortcutBinding(
        LogicalKeyboardKey.arrowUp,
        control: true,
      ),
      MediaShortcutAction.mute: MediaShortcutBinding(
        LogicalKeyboardKey.keyM,
        control: true,
      ),
    };

/// Shortcut persistence and lookup helpers.
class MediaShortcutSettings {
  const MediaShortcutSettings._();

  static Map<MediaShortcutAction, MediaShortcutBinding?> defaults() =>
      Map<MediaShortcutAction, MediaShortcutBinding?>.of(
        kDefaultMediaShortcuts,
      );

  /// Missing actions keep their default; an empty value disables an action.
  static Map<MediaShortcutAction, MediaShortcutBinding?> decode(String? raw) {
    final Map<MediaShortcutAction, MediaShortcutBinding?> result = defaults();
    if (raw == null || raw.isEmpty) return result;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return result;
      for (final MediaShortcutAction action in MediaShortcutAction.values) {
        if (!decoded.containsKey(action.name)) continue;
        final Object? value = decoded[action.name];
        if (value is! String) continue;
        result[action] = value.isEmpty
            ? null
            : MediaShortcutBinding.decode(value);
      }
    } catch (_) {
      // Corrupt preferences fall back to the defaults instead of disabling
      // every shortcut silently.
      return defaults();
    }
    return result;
  }

  static String encode(
    Map<MediaShortcutAction, MediaShortcutBinding?> bindings,
  ) => jsonEncode(<String, String>{
    for (final MediaShortcutAction action in MediaShortcutAction.values)
      action.name: bindings[action]?.encode() ?? '',
  });
}

/// Finds the action bound to [binding], if any.
MediaShortcutAction? mediaShortcutActionFor(
  Map<MediaShortcutAction, MediaShortcutBinding?> bindings,
  MediaShortcutBinding binding,
) {
  for (final MapEntry<MediaShortcutAction, MediaShortcutBinding?> entry
      in bindings.entries) {
    if (entry.value == binding) return entry.key;
  }
  return null;
}

/// Returns the action that already owns [binding], or null when it is free.
MediaShortcutAction? mediaShortcutConflict(
  Map<MediaShortcutAction, MediaShortcutBinding?> bindings, {
  required MediaShortcutAction action,
  required MediaShortcutBinding binding,
}) {
  for (final MapEntry<MediaShortcutAction, MediaShortcutBinding?> entry
      in bindings.entries) {
    if (entry.key != action && entry.value == binding) return entry.key;
  }
  return null;
}

/// While a recorder dialog is open its key presses must not also trigger the
/// global media shortcuts.
class MediaShortcutRecorder {
  MediaShortcutRecorder._();

  static int _depth = 0;
  static bool get active => _depth > 0;

  static void begin() => _depth++;
  static void end() {
    if (_depth > 0) _depth--;
  }
}

String _keyLabel(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.space) return 'Space';
  final String label = key.keyLabel;
  if (label.trim().isNotEmpty) return label.trim();
  final String? debug = key.debugName;
  if (debug != null && debug.isNotEmpty) return debug;
  return 'Key ${key.keyId.toRadixString(16).toUpperCase()}';
}

bool isMediaShortcutModifierKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight ||
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight ||
    key == LogicalKeyboardKey.capsLock ||
    key == LogicalKeyboardKey.numLock ||
    key == LogicalKeyboardKey.scrollLock ||
    key == LogicalKeyboardKey.fn;
