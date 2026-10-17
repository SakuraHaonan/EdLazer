/// Interface preferences shared by the shell and the settings page: which
/// presentation the app forces, and how large the interface is drawn.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

/// Window width below which the shell normally switches to its compact
/// (phone) presentation: bottom tab bar, floating transport, pushed details.
const double kCompactBreakpoint = 720;

/// How the shell picks between the desktop and the mobile presentation.
enum AppUiMode {
  /// Follow the window width — the desktop shell on wide windows, the compact
  /// one on narrow windows.
  auto,

  /// Always draw the desktop shell, whatever the window width.
  desktop,

  /// Always draw the compact shell, whatever the window width.
  mobile,
}

extension AppUiModeLabels on AppUiMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    AppUiMode.auto => '自动选择',
    AppUiMode.desktop => '强制桌面端',
    AppUiMode.mobile => '强制移动端',
  };

  String get detail => switch (this) {
    AppUiMode.auto => '按窗口宽度在桌面端和移动端之间切换',
    AppUiMode.desktop => '始终显示左侧导航栏和桌面播放条',
    AppUiMode.mobile => '始终显示底部标签栏和紧凑播放条',
  };

  /// Parses a persisted [name]; unknown or missing values fall back to
  /// [AppUiMode.auto].
  static AppUiMode parse(String? name) => AppUiMode.values.firstWhere(
    (AppUiMode mode) => mode.name == name,
    orElse: () => AppUiMode.auto,
  );
}

/// Whether the shell should draw its compact presentation.
///
/// [width] is the width available to the shell in logical pixels.
bool useCompactLayout(AppUiMode mode, double width) => switch (mode) {
  AppUiMode.mobile => true,
  AppUiMode.desktop => false,
  AppUiMode.auto => width < kCompactBreakpoint,
};

// ---------------------------------------------------------------------------
// DPI scaling
// ---------------------------------------------------------------------------

/// Smallest interface scale the settings slider offers.
const double kDpiScaleMin = 0.8;

/// Largest interface scale the settings slider offers.
const double kDpiScaleMax = 1.75;

/// Grid the scale snaps to — one slider notch, i.e. five percent.
const double kDpiScaleStep = 0.05;

/// The 1× baseline: logical pixels exactly as the platform reports them.
const double kDpiScaleDefault = 1;

/// Clamps to the supported range and snaps to [kDpiScaleStep] so the slider
/// and a persisted value always agree.
double normalizeDpiScale(double value) {
  if (!value.isFinite) return kDpiScaleDefault;
  final double snapped =
      (value / kDpiScaleStep).roundToDouble() * kDpiScaleStep;
  final double clamped = snapped.clamp(kDpiScaleMin, kDpiScaleMax);
  return (clamped * 100).roundToDouble() / 100;
}

/// Largest scale the automatic mode will pick. The estimate only ever grows
/// the interface, so this is the ceiling for very large workspaces.
const double kAutoDpiScaleMax = 1.75;

/// The workspace the 1× layout is tuned for: a 1920×1080 logical desktop.
const double kDpiReferenceArea = 1920 * 1080;

/// Estimates the interface scale a workspace needs.
///
/// High-resolution displays running at a 100% system scale report a large
/// logical workspace, which renders the app physically small. The estimate
/// therefore scales with the square root of the workspace area relative to a
/// 1080p reference — the same factor as the diagonal, so 2560×1440 lands at
/// about 1.35× and 3840×2160 at the 1.75× ceiling. Small workspaces keep 1×,
/// and the result is never below it: an explicit user or system choice to
/// shrink the interface is respected instead of being second-guessed.
double dpiScaleForWorkspace(Size workspace) {
  final double area = workspace.width * workspace.height;
  if (!area.isFinite || area <= 0) return kDpiScaleDefault;
  final double estimate = math.sqrt(area / kDpiReferenceArea);
  if (estimate <= 1) return kDpiScaleDefault;
  return normalizeDpiScale(estimate.clamp(1, kAutoDpiScaleMax));
}
