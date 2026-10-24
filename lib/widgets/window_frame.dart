import '../l10n/app_localizations.dart';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Window title shown in the custom frame — also pushed to the native
/// window so the taskbar and Alt+Tab agree with the bar.
const String kWindowTitle = 'Lazer';

/// Frame height: 40px = 10 × the 4px base unit. Controls are 46px wide,
/// flush to the right edge the way native caption buttons sit.
const double _barHeight = 40;
const double _buttonWidth = 46;
const double _glyphBox = 18;

/// Whether this run draws its own window frame instead of the system one.
/// Off on web/mobile and under `flutter test` — goldens cover page content
/// only, and no plugin channel is ever touched from the test runtime.
final bool kCustomWindowFrame =
    !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
    !Platform.environment.containsKey('FLUTTER_TEST');

/// Top inset a page must leave so its own controls never slide under the
/// floating caption buttons. Non-zero only where the frame floats over the
/// content (Windows); macOS still reserves a strip above the page.
double get floatingFrameInset =>
    kCustomWindowFrame && Platform.isWindows ? _barHeight : 0;

/// macOS keeps its native traffic lights (they must live top-left there);
/// Windows and Linux draw the custom hairline glyphs on the right instead.
bool get _usesNativeWindowButtons => Platform.isMacOS;

/// Strips the system title bar before the first frame reaches the screen.
/// The runner only shows the window once Flutter has rendered, so the
/// native bar never flashes. No-op off desktop and under tests.
Future<void> initWindowFrame() async {
  if (!kCustomWindowFrame) return;
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: _usesNativeWindowButtons,
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

/// Places the quiet frame strip above the whole app (outside the Navigator,
/// so pushed routes never cover it). Falls through to the plain child
/// wherever the system frame is in charge.
class WindowFrame extends StatelessWidget {
  const WindowFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!kCustomWindowFrame) return child;
    if (Platform.isWindows) {
      // Windows has no traffic lights to reserve space for, so the page owns
      // the whole window and the drag strip with the caption buttons floats on
      // top of it. That keeps the frame inside the app's own surface instead of
      // making it read as a native title bar bolted above the content.
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            Positioned.fill(child: child),
            const Positioned(top: 0, left: 0, right: 0, child: DesktopTitleBar()),
          ],
        ),
      );
    }
    // macOS keeps its own strip: the traffic lights live in it.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          const DesktopTitleBar(),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// The frame strip itself: theme surface, window title on the left, window
/// controls on the right, closed off by a hairline (never a shadow).
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    // A window restored from a saved maximized state must show the restore
    // glyph, not the maximize glyph.
    Future<void>(() async {
      try {
        final bool maximized = await windowManager.isMaximized();
        if (mounted) setState(() => _maximized = maximized);
      } catch (_) {
        // Window state unavailable — assume the default windowed shape.
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  Future<void> _toggleMaximize() async {
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    } catch (_) {
      // Ignore: the window may be gone mid-teardown.
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // Floating over the page means no strip, no title and no hairline: only
    // the caption buttons are drawn on top of whatever the page shows.
    final bool floating = kCustomWindowFrame && Platform.isWindows;
    return DefaultTextStyle(
      style: theme.textTheme.labelMedium!.copyWith(
        decoration: TextDecoration.none,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: _barHeight,
            color: floating ? null : scheme.surface,
            child: DragToMoveArea(
              child: Row(
                children: [
                  // Traffic lights own the left edge on macOS.
                  SizedBox(
                    width: _usesNativeWindowButtons ? 84 : (floating ? 8 : 16),
                  ),
                  // Expanded (not Flexible): the title yields its unused width
                  // to the controls so they stay flush against the edge.
                  Expanded(
                    child: floating
                        ? const SizedBox.shrink()
                        : Text(
                            kWindowTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                  if (!_usesNativeWindowButtons)
                    Padding(
                      // Floating controls sit a little inboard of the corner so
                      // they read as part of the page instead of hugging it.
                      padding: EdgeInsets.only(
                        right: floating ? 10 : 0,
                        top: floating ? 6 : 0,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          _WindowButton(
                            control: _FrameControl.minimize,
                            onPressed: () => windowManager.minimize(),
                          ),
                          _WindowButton(
                            control: _maximized
                                ? _FrameControl.restore
                                : _FrameControl.maximize,
                            onPressed: _toggleMaximize,
                          ),
                          _WindowButton(
                            control: _FrameControl.close,
                            onPressed: () => windowManager.close(),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!floating) Container(height: 1, color: scheme.outlineVariant),
        ],
      ),
    );
  }
}

enum _FrameControl { minimize, maximize, restore, close }

/// One caption button: flat fill, no radius, no shadow. Hover moves the
/// tone (secondary container for the quiet controls, the error fill for
/// close).
class _WindowButton extends StatefulWidget {
  const _WindowButton({required this.control, required this.onPressed});

  final _FrameControl control;
  final VoidCallback onPressed;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  static final Map<_FrameControl, String> _semantics = <_FrameControl, String>{
    _FrameControl.minimize: '最小化',
    _FrameControl.maximize: '最大化',
    _FrameControl.restore: '还原窗口',
    _FrameControl.close: '关闭窗口',
  };

  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool isClose = widget.control == _FrameControl.close;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Windows floats these buttons over the page, and the page can be dark (the
    // now-playing surface), so they carry their own translucent chip instead of
    // relying on the strip behind them.
    final bool floating = kCustomWindowFrame && Platform.isWindows;
    final Color background = !_hovering
        ? Colors.transparent
        : isClose
        ? scheme.error
        : scheme.secondaryContainer;
    final Color glyph = !_hovering
        ? scheme.onSurfaceVariant
        : isClose
        ? scheme.onError
        : scheme.onSecondaryContainer;
    final Widget glyphView = SizedBox(
      width: _glyphBox,
      height: _glyphBox,
      child: CustomPaint(
        painter: _ControlGlyphPainter(control: widget.control, color: glyph),
      ),
    );

    return Semantics(
      button: true,
      label: context.tr(_semantics[widget.control]!),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: _buttonWidth,
            height: _barHeight,
            color: floating ? Colors.transparent : background,
            alignment: Alignment.center,
            child: floating
                ? Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _hovering
                          ? background
                          : scheme.surface.withValues(alpha: 0.72),
                      shape: BoxShape.circle,
                    ),
                    child: glyphView,
                  )
                : glyphView,
          ),
        ),
      ),
    );
  }
}

/// 1px hairline glyphs drawn on half-pixel seams so they stay crisp:
/// a bar, a square, the stacked pair for restore, a cross for close.
class _ControlGlyphPainter extends CustomPainter {
  const _ControlGlyphPainter({required this.control, required this.color});

  final _FrameControl control;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final Paint stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    switch (control) {
      case _FrameControl.minimize:
        canvas.drawLine(
          Offset(cx - 4.5, cy + 0.5),
          Offset(cx + 4.5, cy + 0.5),
          stroke,
        );
      case _FrameControl.maximize:
        canvas.drawRect(
          Rect.fromLTRB(cx - 4.5, cy - 4.5, cx + 4.5, cy + 4.5),
          stroke,
        );
      case _FrameControl.restore:
        // Back window shows only its top and right edges — the parts the
        // front square doesn't already cover.
        final Path back = Path()
          ..moveTo(cx - 1.5, cy - 7.5)
          ..lineTo(cx + 7.5, cy - 7.5)
          ..lineTo(cx + 7.5, cy + 1.5);
        canvas.drawPath(back, stroke);
        canvas.drawRect(
          Rect.fromLTRB(cx - 7.5, cy - 1.5, cx + 1.5, cy + 7.5),
          stroke,
        );
      case _FrameControl.close:
        canvas.drawLine(
          Offset(cx - 4.5, cy - 4.5),
          Offset(cx + 4.5, cy + 4.5),
          stroke,
        );
        canvas.drawLine(
          Offset(cx + 4.5, cy - 4.5),
          Offset(cx - 4.5, cy + 4.5),
          stroke,
        );
    }
  }

  @override
  bool shouldRepaint(_ControlGlyphPainter oldDelegate) =>
      oldDelegate.control != control || oldDelegate.color != color;
}
