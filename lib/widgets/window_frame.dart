import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_title_area.dart';

export 'window_title_area.dart';

/// Whether this run draws its own window frame instead of the system one.
/// Off on web/mobile and under `flutter test` — goldens cover page content
/// only, and no plugin channel is ever touched from the test runtime.
final bool kCustomWindowFrame =
    !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
    !Platform.environment.containsKey('FLUTTER_TEST');

/// Strips the system title bar before the first frame reaches the screen. The
/// runner only shows the window once Flutter has rendered, so the native bar
/// never flashes. No-op off desktop and under tests.
Future<void> initWindowFrame() async {
  if (!kCustomWindowFrame) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: usesNativeWindowButtons,
    ),
  );
  if (Platform.isWindows) {
    await windowManager.setAsFrameless();
    // Keep the DWM frame on Windows: it is what supplies the drop shadow and
    // the Windows 11 rounded corners. Turning it off (the previous behaviour)
    // left the window a flat white rectangle with no edge against the equally
    // white desktop behind it.
    await windowManager.setHasShadow(true);
  } else if (Platform.isMacOS) {
    await windowManager.setHasShadow(false);
  }
  await windowManager.setTitle(kWindowTitle);
}

/// Places the independent title area above the whole app (outside the
/// Navigator, so pushed routes and the now-playing page never cover it).
///
/// The strip carries the window title and — on Windows and Linux — the
/// minimize, fullscreen and close buttons. macOS keeps its native traffic
/// lights in the same strip. Falls through to the plain child wherever the
/// system frame is in charge.
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kCustomWindowFrame) return child;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: <Widget>[
          const WindowTitleArea(),
          Expanded(child: child),
        ],
      ),
    );
  }
}
