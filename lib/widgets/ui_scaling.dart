import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';

/// Estimates the automatic interface scale for the window's workspace.
///
/// The workspace is the window's logical size — `physicalSize / dpr` — which
/// already folds in the system scale the platform reports. Flutter cannot see
/// a desktop display's physical size (`Display.size` is invalid off Linux), so
/// the window is the only honest signal available.
double automaticDpiScale(BuildContext context) {
  final MediaQueryData? media = MediaQuery.maybeOf(context);
  Size workspace = media?.size ?? Size.zero;
  if (workspace.isEmpty) {
    final view = View.maybeOf(context);
    final Size physical = view?.physicalSize ?? Size.zero;
    final double dpr = view?.devicePixelRatio ?? 1;
    if (!physical.isEmpty && dpr > 0) workspace = physical / dpr;
  }
  return dpiScaleForWorkspace(workspace);
}

/// Publishes the resolved scales to the subtree so the settings page can show
/// the value the shell actually applies — the child is laid out at
/// `size / scale`, so reading [MediaQuery.sizeOf] from inside would lie.
class UiMetrics extends InheritedWidget {
  const UiMetrics({
    super.key,
    required this.scale,
    required this.autoScale,
    required super.child,
  });

  /// Scale applied to the interface right now.
  final double scale;

  /// Scale the automatic mode would apply for this window.
  final double autoScale;

  static UiMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiMetrics>();

  /// The scale the interface is currently drawn at.
  static double scaleOf(BuildContext context) =>
      maybeOf(context)?.scale ?? kDpiScaleDefault;

  /// The automatic scale for the window, from the nearest [UiMetrics] or
  /// computed from the view when there is none.
  static double autoScaleOf(BuildContext context) =>
      maybeOf(context)?.autoScale ?? automaticDpiScale(context);

  @override
  bool updateShouldNotify(UiMetrics oldWidget) =>
      oldWidget.scale != scale || oldWidget.autoScale != autoScale;
}

/// Applies the interface scale from [AppState].
///
/// Layout is scaled, not just text: the child is laid out in a workspace
/// divided by the scale and painted back through a matching transform, so
/// every row, icon, hit target and the custom window frame grow together —
/// what a desktop app's DPI setting is expected to do. Text stays crisp
/// because the transform is applied at paint time, not by upscaling a bitmap.
class UiScaling extends StatelessWidget {
  const UiScaling({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final double autoScale = automaticDpiScale(context);
    final double scale = normalizeDpiScale(
      state.autoDpiScale ? autoScale : state.dpiScale,
    );
    final Widget scaled = scale == kDpiScaleDefault
        ? child
        : _ScaledInterface(scale: scale, child: child);
    return UiMetrics(scale: scale, autoScale: autoScale, child: scaled);
  }
}

class _ScaledInterface extends StatelessWidget {
  const _ScaledInterface({required this.scale, required this.child});

  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size bounds = constraints.biggest;
        // Unbounded (a scroll view, a test harness): nothing to scale against.
        if (!bounds.isFinite || bounds.width <= 0 || bounds.height <= 0) {
          return child;
        }
        final Size workspace = Size(
          bounds.width / scale,
          bounds.height / scale,
        );
        return MediaQuery(
          data: media.copyWith(size: workspace),
          child: Align(
            alignment: AlignmentDirectional.topStart,
            child: Transform.scale(
              scale: scale,
              alignment: AlignmentDirectional.topStart,
              child: SizedBox(
                width: workspace.width,
                height: workspace.height,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Rounds a scale to whole percent for display.
String formatDpiScale(double scale) => '${(scale * 100).round()}%';
