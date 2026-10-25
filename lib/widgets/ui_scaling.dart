import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../tv/tv_mode.dart';

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

/// Whether this device is a car head unit, from the platform's own report.
bool detectCarDisplay(BuildContext context) {
  final MediaQueryData? media = MediaQuery.maybeOf(context);
  if (media == null) return false;
  final double dpr = media.devicePixelRatio;
  final Size physical = media.size * (dpr > 0 ? dpr : 1);
  return looksLikeCarDisplay(
    platform: defaultTargetPlatform,
    physicalSize: physical,
    devicePixelRatio: dpr,
  );
}

/// Whether the car profile applies to [surface] on this device.
bool carSurfaceOf(BuildContext context, AppSurface surface) =>
    carSurfaceActive(surface, detected: detectCarDisplay(context));

/// Clamps a scale to the profile floor and the slider ceiling.
double profileDpiScale(double value, {required double floor}) =>
    normalizeDpiScale(value.clamp(floor, kDpiScaleMax));

/// Publishes the resolved scales to the subtree so the settings page can show
/// the value the shell actually applies — the child is laid out at
/// `size / scale`, so reading [MediaQuery.sizeOf] from inside would lie.
class UiMetrics extends InheritedWidget {
  const UiMetrics({
    super.key,
    required this.scale,
    required this.autoScale,
    required this.minScale,
    required this.car,
    required this.tv,
    required super.child,
  });

  /// Scale applied to the interface right now.
  final double scale;

  /// Scale the automatic mode would apply for this window.
  final double autoScale;

  /// Smallest scale the manual slider offers under the active profile.
  final double minScale;

  /// Whether the car head-unit profile is in effect.
  final bool car;

  /// Whether the television (ten-foot, D-pad) profile is in effect.
  final bool tv;

  static UiMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiMetrics>();

  /// The scale the interface is currently drawn at.
  static double scaleOf(BuildContext context) =>
      maybeOf(context)?.scale ?? kDpiScaleDefault;

  /// The automatic scale for the window, from the nearest [UiMetrics] or
  /// computed from the view when there is none.
  static double autoScaleOf(BuildContext context) =>
      maybeOf(context)?.autoScale ?? automaticDpiScale(context);

  /// The slider floor of the active profile.
  static double minScaleOf(BuildContext context) =>
      maybeOf(context)?.minScale ?? kDpiScaleMin;

  /// Whether the car profile is active here.
  static bool carOf(BuildContext context) => maybeOf(context)?.car ?? false;

  /// Whether the television profile is active here.
  static bool tvOf(BuildContext context) => maybeOf(context)?.tv ?? false;

  @override
  bool updateShouldNotify(UiMetrics oldWidget) =>
      oldWidget.scale != scale ||
      oldWidget.autoScale != autoScale ||
      oldWidget.minScale != minScale ||
      oldWidget.car != car ||
      oldWidget.tv != tv;
}

/// Applies the interface scale from [AppState].
///
/// Layout is scaled, not just text: the child is laid out in a workspace
/// divided by the scale and painted back through a matching transform, so
/// every row, icon, hit target and the custom window frame grow together —
/// what a desktop app's DPI setting is expected to do. Text stays crisp
/// because the transform is applied at paint time, not by upscaling a bitmap.
///
/// The car profile raises the floor: on a head unit the interface never drops
/// to desktop density, whether the automatic mode or the slider is in charge.
class UiScaling extends StatelessWidget {
  const UiScaling({super.key, required this.state, required this.child});

  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DeviceProfile profile = resolveDeviceProfile(
      state.surface,
      television: state.deviceIsTelevision,
      car: detectCarDisplay(context),
    );
    final bool car = profile == DeviceProfile.car;
    final bool tv = profile == DeviceProfile.tv;
    final double floor = dpiScaleFloor(car: car, tv: tv);
    final double autoScale = profileDpiScale(
      automaticDpiScale(context),
      floor: floor,
    );
    final double scale = profileDpiScale(
      state.autoDpiScale ? autoScale : state.dpiScale,
      floor: floor,
    );
    final Widget scaled = scale == kDpiScaleDefault
        ? child
        : _ScaledInterface(scale: scale, child: child);
    return TvScope(
      // Remote navigation follows the input device, not the density choice: a
      // television told to use standard density still has no touch screen.
      active: tv || state.deviceIsTelevision || state.surface == AppSurface.tv,
      child: UiMetrics(
        scale: scale,
        autoScale: autoScale,
        minScale: floor,
        car: car,
        tv: tv,
        child: scaled,
      ),
    );
  }
}

/// Roomier Material metrics for the car and television profiles.
///
/// The global scale already enlarges everything; this additionally swaps the
/// compact desktop density Flutter picks by default for an expanded one and
/// restores the padded 48 px tap target around framework controls (icon
/// buttons, dropdowns, list tiles) that a moving hand or a remote needs. On a
/// television it also strengthens Material's focus wash, which is the only
/// feedback those controls give when the D-pad lands on them.
class CarMetrics extends StatelessWidget {
  const CarMetrics({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bool car = UiMetrics.carOf(context);
    final bool tv = UiMetrics.tvOf(context);
    final bool remote = TvScope.isActive(context);
    if (!car && !tv && !remote) return child;
    final ThemeData theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        visualDensity: const VisualDensity(horizontal: 1, vertical: 1),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        focusColor: remote
            ? theme.colorScheme.primary.withValues(alpha: .32)
            : theme.focusColor,
      ),
      child: child,
    );
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
