/// Interface preferences shared by the shell and the settings page: which
/// presentation the app forces, how large the interface is drawn, and which
/// device form the density is tuned for.
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show TargetPlatform;

/// Window width below which the shell normally switches to its compact
/// (phone) presentation: bottom tab bar, floating transport, pushed details.
const double kCompactBreakpoint = 720;

/// Which interface the app draws.
///
/// [nextgen] is the parchment shell this build has always shipped. [legacy] is
/// the interface ported from the Lazer project (`E:\projects\Lazer`): the
/// Material 3 chrome built around the blue-grey night palette, the rail, the
/// playlist cards and the transport bar of that app.
enum AppUiStyle {
  nextgen,
  legacy,
}

/// How the legacy shell picks its accent palette.
///
/// [fixed] is the Lazer blue-grey scheme. [nowPlaying] derives a Material 3
/// scheme from the current cover — the legacy `LazerPalette.NowPlaying`.
enum LegacyPaletteMode {
  fixed,
  nowPlaying,
}

extension LegacyPaletteModeLabels on LegacyPaletteMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    LegacyPaletteMode.fixed => '默认',
    LegacyPaletteMode.nowPlaying => '跟随当前歌曲',
  };

  String get detail => switch (this) {
    LegacyPaletteMode.fixed => 'Lazer 的蓝灰配色',
    LegacyPaletteMode.nowPlaying => '由当前封面主色生成整套配色',
  };

  /// Parses a persisted [name]; unknown or missing values keep the fixed
  /// scheme.
  static LegacyPaletteMode parse(String? name) =>
      LegacyPaletteMode.values.firstWhere(
        (LegacyPaletteMode mode) => mode.name == name,
        orElse: () => LegacyPaletteMode.fixed,
      );
}

/// How the legacy shell paints its page backdrop.
///
/// The flowing album-colour canvas is ported from the Lazer project's
/// `AlbumFlowBackground`; [nowPlayingDynamic] animates it, [nowPlayingStatic]
/// freezes the palette to one flat base, and [off] leaves the theme surface.
enum LegacyBackgroundMode {
  nowPlayingDynamic,
  nowPlayingStatic,
  off,
}

extension LegacyBackgroundModeLabels on LegacyBackgroundMode {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    LegacyBackgroundMode.nowPlayingDynamic => '跟随当前歌曲（流动）',
    LegacyBackgroundMode.nowPlayingStatic => '当前歌曲纯色',
    LegacyBackgroundMode.off => '不使用',
  };

  /// Parses a persisted [name]; unknown or missing values keep the flowing
  /// canvas the port ships with.
  static LegacyBackgroundMode parse(String? name) =>
      LegacyBackgroundMode.values.firstWhere(
        (LegacyBackgroundMode mode) => mode.name == name,
        orElse: () => LegacyBackgroundMode.nowPlayingDynamic,
      );
}

extension AppUiStyleLabels on AppUiStyle {
  /// Product name, shown as written in both catalogues.
  String get label => switch (this) {
    AppUiStyle.nextgen => 'Nextgen UI',
    AppUiStyle.legacy => 'Legacy UI',
  };

  /// Chinese source string, translated through `context.tr`.
  String get detail => switch (this) {
    AppUiStyle.nextgen => '当前的纸张式界面：编辑排版、细腻动效',
    AppUiStyle.legacy => '移植自 Lazer 的经典界面：深色 Material 3 与左侧导航',
  };

  /// Parses a persisted [name]; unknown or missing values fall back to the
  /// shipped interface.
  static AppUiStyle parse(String? name) => AppUiStyle.values.firstWhere(
    (AppUiStyle style) => style.name == name,
    orElse: () => AppUiStyle.nextgen,
  );
}

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

// ---------------------------------------------------------------------------
// Device form
// ---------------------------------------------------------------------------

/// Which device the interface is drawn for.
///
/// The interface is designed at desktop density: a 15 px body, 48 px controls,
/// rows a mouse can hit. A car head unit is a different place to use it — the
/// screen is large but sits an arm's length away behind glass, it is touched in
/// motion, and its pixels are not dense (a 1280×720 or 1920×720 panel reports a
/// 100% density, so the same logical pixels are physically big but far away).
/// The car profile answers that with a larger interface floor and roomier
/// controls.
enum AppSurface {
  /// Recognise a head unit from the platform and switch by itself.
  auto,

  /// Whatever density the platform reports.
  standard,

  /// Large, arm's-length controls, whatever the platform reports.
  car,
}

extension AppSurfaceLabels on AppSurface {
  /// Chinese source string, translated through `context.tr`.
  String get label => switch (this) {
    AppSurface.auto => '自动选择',
    AppSurface.standard => '标准',
    AppSurface.car => '车机',
  };

  String get detail => switch (this) {
    AppSurface.auto => '在 Android 车机上自动放大；其余设备保持标准密度',
    AppSurface.standard => '按平台上报的密度显示，桌面与手机默认如此',
    AppSurface.car => '放大界面与控件，适合远距离、行进中的触控',
  };

  /// Parses a persisted [name]; unknown or missing values fall back to
  /// [AppSurface.auto].
  static AppSurface parse(String? name) => AppSurface.values.firstWhere(
    (AppSurface surface) => surface.name == name,
    orElse: () => AppSurface.auto,
  );
}

/// Smallest interface scale the car profile allows.
///
/// A head unit is read from a metre away, through glass, while the car moves:
/// 1× desktop density is what made the interface look tiny there. The floor is
/// a starting point the DPI slider can still raise.
const double kCarScaleMin = 1.35;

/// Physical pixels below which a display is never a head unit.
const Size kCarMinPhysicalSize = Size(960, 540);

/// Highest device pixel ratio a head unit reports. Phones report 2–3.5×, so a
/// 1× panel is either an embedded/10-foot display or an old, low-density one —
/// both of which want the larger treatment.
const double kCarMaxDevicePixelRatio = 1.5;

/// Best-effort head-unit recognition.
///
/// The app cannot ask Android whether it is running on a vehicle head unit
/// without platform code, so this reads the shape such a device always has:
/// an embedded Android panel that renders at (or near) one physical pixel per
/// logical pixel, is landscape, and is at least 960×540. Android TV boxes pass
/// the same test and want the same large, far-viewed interface, so they share
/// it; phones (density ≥ 2) and portrait tablets never match. Desktop
/// platforms are excluded on purpose — a window's size says nothing about the
/// display behind it, so there the choice stays manual.
bool looksLikeCarDisplay({
  required TargetPlatform platform,
  required Size physicalSize,
  required double devicePixelRatio,
}) {
  if (platform != TargetPlatform.android) return false;
  if (!devicePixelRatio.isFinite || devicePixelRatio <= 0) return false;
  if (devicePixelRatio > kCarMaxDevicePixelRatio) return false;
  if (physicalSize.width < kCarMinPhysicalSize.width) return false;
  if (physicalSize.height < kCarMinPhysicalSize.height) return false;
  // Head units are mounted in landscape; a portrait window is not one.
  return physicalSize.width > physicalSize.height;
}

/// Whether the car profile is in effect for [surface], given the platform's
/// own answer ([detected]).
bool carSurfaceActive(AppSurface surface, {required bool detected}) =>
    switch (surface) {
      AppSurface.car => true,
      AppSurface.standard => false,
      AppSurface.auto => detected,
    };

/// The smallest interface scale the active profile allows.
double dpiScaleFloor({required bool car}) => car ? kCarScaleMin : kDpiScaleMin;
