import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../state/app_state.dart';
import '../state/media_shortcuts.dart';

/// Listens to hardware key presses for the globally configured media
/// shortcuts.
///
/// The handler sits above the navigator so it keeps working on every page and
/// over the player. Text fields are skipped, and a recorder dialog suspends it
/// while it captures a new combination.
class MediaShortcutListener extends StatefulWidget {
  const MediaShortcutListener({
    super.key,
    required this.state,
    required this.child,
  });

  final AppState state;
  final Widget child;

  @override
  State<MediaShortcutListener> createState() => _MediaShortcutListenerState();
}

class _MediaShortcutListenerState extends State<MediaShortcutListener> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (MediaShortcutRecorder.active) return false;
    if (_isEditingText()) return false;

    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final MediaShortcutBinding pressed = MediaShortcutBinding(
      event.logicalKey,
      control: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
      meta: keyboard.isMetaPressed,
    );
    final MediaShortcutAction? action = mediaShortcutActionFor(
      widget.state.mediaShortcuts,
      pressed,
    );
    if (action == null) return false;
    _perform(action);
    return true;
  }

  void _perform(MediaShortcutAction action) {
    final AppState state = widget.state;
    switch (action) {
      case MediaShortcutAction.playPause:
        state.togglePlay();
      case MediaShortcutAction.previousTrack:
        state.previous();
      case MediaShortcutAction.nextTrack:
        state.next();
      case MediaShortcutAction.seekBackward:
        state.seekBy(const Duration(seconds: -5));
      case MediaShortcutAction.seekForward:
        state.seekBy(const Duration(seconds: 5));
      case MediaShortcutAction.volumeDown:
        unawaited(state.adjustVolume(-0.05));
      case MediaShortcutAction.volumeUp:
        unawaited(state.adjustVolume(0.05));
      case MediaShortcutAction.mute:
        unawaited(state.toggleMute());
    }
  }

  bool _isEditingText() {
    final BuildContext? context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorStateOfType<EditableTextState>() != null;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
