import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import '../theme/design_tokens.dart' show AppFonts;

/// The legacy interface's design tokens, ported from the Lazer project
/// (`E:\projects\Lazer`, `shared/src/commonMain/.../LazerTheme.kt`).
///
/// The legacy shell is Material 3 on a blue-grey night palette: a lake-blue
/// accent, clay for warmth, paper and night-paper neutrals, and a serif-free
/// type ramp that opens at 34 sp and bottoms out at 11 sp.
class LegacyTokens {
  const LegacyTokens._();

  // Light
  static const Color paper = Color(0xFFF7F5EF);
  static const Color paperRaised = Color(0xFFFCFAF5);
  static const Color lakeBlue = Color(0xFF5F91AC);
  static const Color deepBlue = Color(0xFF365F73);
  static const Color ink = Color(0xFF26363D);
  static const Color quietInk = Color(0xFF627279);
  static const Color warmClay = Color(0xFFB88769);

  // Dark
  static const Color nightPaper = Color(0xFF1D282D);
  static const Color nightRaised = Color(0xFF253238);
  static const Color nightInk = Color(0xFFE7ECEB);
  static const Color nightQuietInk = Color(0xFFAAB8BC);
  static const Color nightBlue = Color(0xFF91BED3);

  /// Page padding and the rail width the legacy desktop shell uses.
  static const double railWidth = 208;
  static const double pagePadding = 28;
  static const double playerBarHeight = 84;
  static const double compactPlayerBarHeight = 64;
}

/// `LightColors` / `DarkColors` from `LazerTheme.kt`.
ColorScheme legacyColorScheme(Brightness brightness) =>
    brightness == Brightness.dark ? _legacyDark : _legacyLight;

/// The legacy `MaterialTheme.colorScheme.background` (paper / night paper).
Color legacyPageBackground(Brightness brightness) =>
    brightness == Brightness.dark
    ? LegacyTokens.nightPaper
    : LegacyTokens.paper;

/// The same page tone for whichever scheme is active — fixed or album-seeded.
Color legacyPageBackgroundOf(ColorScheme scheme) => scheme.brightness ==
        Brightness.dark
    ? scheme.surfaceContainerLowest
    : scheme.surfaceContainerLow;

const ColorScheme _legacyLight = ColorScheme(
  brightness: Brightness.light,
  primary: LegacyTokens.lakeBlue,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFDDECF3),
  onPrimaryContainer: Color(0xFF244B5E),
  secondary: Color(0xFF6E858F),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE5ECEE),
  onSecondaryContainer: LegacyTokens.ink,
  tertiary: LegacyTokens.warmClay,
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFF1E3D8),
  onTertiaryContainer: Color(0xFF60442F),
  error: Color(0xFFB3261E),
  onError: Color(0xFFFFFFFF),
  surface: LegacyTokens.paperRaised,
  onSurface: LegacyTokens.ink,
  onSurfaceVariant: LegacyTokens.quietInk,
  surfaceContainerHighest: Color(0xFFE9EEED),
  surfaceContainerLow: LegacyTokens.paper,
  surfaceContainerLowest: Color(0xFFFFFFFF),
  outline: Color(0xFFA8B5B8),
  outlineVariant: Color(0xFFD7DEDD),
  inverseSurface: LegacyTokens.ink,
  onInverseSurface: LegacyTokens.paper,
  inversePrimary: LegacyTokens.nightBlue,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

const ColorScheme _legacyDark = ColorScheme(
  brightness: Brightness.dark,
  primary: LegacyTokens.nightBlue,
  onPrimary: Color(0xFF153844),
  primaryContainer: Color(0xFF294B5A),
  onPrimaryContainer: Color(0xFFDCEFF7),
  secondary: Color(0xFF8AA3AD),
  onSecondary: Color(0xFF1B2A30),
  secondaryContainer: Color(0xFF304047),
  onSecondaryContainer: LegacyTokens.nightInk,
  tertiary: Color(0xFFD2A388),
  onTertiary: Color(0xFF482A1B),
  tertiaryContainer: Color(0xFF5A3A28),
  onTertiaryContainer: Color(0xFFF5DFD1),
  error: Color(0xFFE39A9A),
  onError: Color(0xFF3A1414),
  surface: LegacyTokens.nightRaised,
  onSurface: LegacyTokens.nightInk,
  onSurfaceVariant: LegacyTokens.nightQuietInk,
  surfaceContainerHighest: Color(0xFF314047),
  surfaceContainerLow: Color(0xFF222E34),
  surfaceContainerLowest: LegacyTokens.nightPaper,
  outline: Color(0xFF687A81),
  outlineVariant: Color(0xFF3B4B51),
  inverseSurface: LegacyTokens.nightInk,
  onInverseSurface: LegacyTokens.nightPaper,
  inversePrimary: LegacyTokens.lakeBlue,
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// `LazerTypography` from `LazerTheme.kt`, mapped onto Material's text roles.
const TextTheme legacyTextTheme = TextTheme(
  displaySmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 34,
    height: 42 / 34,
    letterSpacing: -0.6,
  ),
  headlineMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 25,
    height: 33 / 25,
    letterSpacing: -0.25,
  ),
  headlineSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 21,
    height: 29 / 21,
  ),
  titleLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w600,
    fontSize: 18,
    height: 25 / 18,
  ),
  titleMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 15,
    height: 22 / 15,
  ),
  titleSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    height: 20 / 13,
  ),
  bodyLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 24 / 15,
  ),
  bodyMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 22 / 14,
  ),
  bodySmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 19 / 12,
  ),
  labelLarge: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 14,
    height: 20 / 14,
  ),
  labelMedium: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w500,
    fontSize: 12,
    height: 18 / 12,
  ),
  labelSmall: TextStyle(
    fontFamily: AppFonts.sans,
    fontWeight: FontWeight.w400,
    fontSize: 11,
    height: 16 / 11,
  ),
);

/// ThemeData for the legacy shell. The window itself paints the page colour,
/// so `scaffoldBackgroundColor` follows the legacy background, not the raised
/// surface. Pass [seed] to derive the accent palette from the current cover
/// (the legacy `LazerPalette.NowPlaying`).
ThemeData buildLegacyTheme({
  Brightness brightness = Brightness.light,
  Color? seed,
}) {
  final ColorScheme scheme = seed == null
      ? legacyColorScheme(brightness)
      : ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  final bool dark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    textTheme: legacyTextTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    ),
    scaffoldBackgroundColor: legacyPageBackgroundOf(scheme),
    canvasColor: scheme.surface,
    dividerColor: scheme.outlineVariant,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      },
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.secondaryContainer,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF2C3A40) : const Color(0xFFEDF1F1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(28),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: scheme.onSurface),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: scheme.primary,
      inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.16),
      thumbColor: scheme.primary,
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      trackShape: const RoundedRectSliderTrackShape(),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: dark ? const Color(0xFF35464D) : LegacyTokens.ink,
      contentTextStyle: legacyTextTheme.bodyMedium?.copyWith(
        color: LegacyTokens.nightInk,
      ),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF35464D) : LegacyTokens.ink,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: legacyTextTheme.labelMedium?.copyWith(
        color: LegacyTokens.nightInk,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.onSurface.withValues(alpha: 0.12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(
        scheme.onSurface.withValues(alpha: 0.24),
      ),
      radius: const Radius.circular(999),
    ),
  );
}
