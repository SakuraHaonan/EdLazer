import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The Apple Music accent and glass tones used by the desktop now-playing page.
///
/// This page is intentionally not Material 3: Apple Music's immersive player is
/// a platform-native composition of blurred artwork, system typography, white
/// controls and a single red accent. Everything else in the app stays on the
/// shared Material 3 theme; this local theme only wraps the player page and its
/// docked panels.
abstract final class AppleMusicColors {
  static const Color accent = Color(0xFFFA2D48);
  static const Color accentDim = Color(0xFFB11F34);
  static const Color background = Color(0xFF0A0A0B);
  static const Color panel = Color(0xF21C1C1E);
  static const Color panelRaised = Color(0xFF2C2C2E);
  static const Color glass = Color(0x1FFFFFFF);
  static const Color glassHover = Color(0x33FFFFFF);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xB3FFFFFF);
  static const Color textTertiary = Color(0x66FFFFFF);
  static const Color hairline = Color(0x1FFFFFFF);
}

/// A system-font, dark, Apple Music-flavoured theme for the immersive player.
///
/// No `fontFamily` is supplied: Flutter's platform typography already picks the
/// native UI face (SF Pro on Apple platforms, Segoe UI on Windows, Ubuntu on
/// Linux). MiSans and the CJK system faces remain in the fallback chain.
ThemeData buildAppleMusicTheme() {
  const ColorScheme scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppleMusicColors.textPrimary,
    onPrimary: Color(0xFF000000),
    primaryContainer: Color(0xFF3A3A3C),
    onPrimaryContainer: AppleMusicColors.textPrimary,
    primaryFixed: Color(0xFFFFFFFF),
    primaryFixedDim: Color(0xFFD1D1D6),
    onPrimaryFixed: Color(0xFF000000),
    onPrimaryFixedVariant: Color(0xFF3A3A3C),
    secondary: AppleMusicColors.accent,
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0x26FFFFFF),
    onSecondaryContainer: AppleMusicColors.textPrimary,
    secondaryFixed: Color(0xFFFFB3BC),
    secondaryFixedDim: AppleMusicColors.accent,
    onSecondaryFixed: Color(0xFF3A0010),
    onSecondaryFixedVariant: Color(0xFF8A1424),
    tertiary: Color(0xFF0A84FF),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFF0A3A66),
    onTertiaryContainer: Color(0xFFD6E9FF),
    error: Color(0xFFFF453A),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFF5A1714),
    onErrorContainer: Color(0xFFFFDAD6),
    surface: AppleMusicColors.panel,
    onSurface: AppleMusicColors.textPrimary,
    surfaceDim: Color(0xFF0A0A0B),
    surfaceBright: Color(0xFF3A3A3C),
    surfaceContainerLowest: Color(0xFF000000),
    surfaceContainerLow: AppleMusicColors.panel,
    surfaceContainer: Color(0xFF242426),
    surfaceContainerHigh: AppleMusicColors.panelRaised,
    surfaceContainerHighest: Color(0xFF3A3A3C),
    onSurfaceVariant: AppleMusicColors.textSecondary,
    outline: Color(0x66FFFFFF),
    outlineVariant: AppleMusicColors.hairline,
    inverseSurface: Color(0xFFFFFFFF),
    onInverseSurface: Color(0xFF000000),
    inversePrimary: AppleMusicColors.accent,
    surfaceTint: Colors.transparent,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
  final Typography typography = Typography.material2021(
    platform: defaultTargetPlatform,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    typography: typography,
    textTheme: typography.white,
    primaryTextTheme: typography.white,
    fontFamilyFallback: const <String>[
      'SF Pro Text',
      'SF Pro Display',
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      AppFonts.sans,
      'sans-serif',
    ],
    scaffoldBackgroundColor: AppleMusicColors.background,
    canvasColor: AppleMusicColors.panel,
    dividerColor: AppleMusicColors.hairline,
    splashFactory: InkRipple.splashFactory,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: AppleMusicColors.textSecondary,
        highlightColor: Colors.transparent,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppleMusicColors.textPrimary,
        textStyle: typography.white.labelLarge,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppleMusicColors.textPrimary,
        foregroundColor: Colors.black,
        shape: const StadiumBorder(),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppleMusicColors.textPrimary,
        side: const BorderSide(color: Color(0x40FFFFFF)),
        shape: const StadiumBorder(),
      ),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: AppleMusicColors.textPrimary,
      inactiveTrackColor: Color(0x33FFFFFF),
      secondaryActiveTrackColor: Color(0x59FFFFFF),
      thumbColor: AppleMusicColors.textPrimary,
      overlayColor: Color(0x14FFFFFF),
      valueIndicatorColor: AppleMusicColors.textPrimary,
      valueIndicatorTextStyle: TextStyle(color: Colors.black),
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      trackShape: RoundedRectSliderTrackShape(),
      tickMarkShape: SliderTickMarkShape.noTickMark,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppleMusicColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      textStyle: typography.white.bodyMedium,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll<Color?>(
          AppleMusicColors.panel,
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double?>(8),
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppleMusicColors.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(16)),
      ),
      titleTextStyle: typography.white.titleLarge,
      contentTextStyle: typography.white.bodyMedium?.copyWith(
        color: AppleMusicColors.textSecondary,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppleMusicColors.panel,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: AppleMusicColors.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppleMusicColors.panel,
      contentTextStyle: typography.white.bodyMedium,
      actionTextColor: AppleMusicColors.accent,
      behavior: SnackBarBehavior.floating,
      elevation: 8,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: const BoxDecoration(
        color: AppleMusicColors.panel,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: typography.white.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      waitDuration: const Duration(milliseconds: 420),
    ),
    dividerTheme: const DividerThemeData(
      color: AppleMusicColors.hairline,
      thickness: 1,
      space: 1,
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(Color(0x40FFFFFF)),
      radius: Radius.circular(999),
      thickness: WidgetStatePropertyAll<double>(6),
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppleMusicColors.accent,
      selectionColor: Color(0x4DFA2D48),
      selectionHandleColor: AppleMusicColors.accent,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? Colors.white
            : const Color(0xFF8E8E93),
      ),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (Set<WidgetState> states) => states.contains(WidgetState.selected)
            ? AppleMusicColors.accent
            : const Color(0x33FFFFFF),
      ),
      trackOutlineColor: const WidgetStatePropertyAll<Color>(
        Colors.transparent,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0x14FFFFFF),
      hintStyle: typography.white.bodyMedium?.copyWith(
        color: AppleMusicColors.textTertiary,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: Color(0x1FFFFFFF)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: AppleMusicColors.accent, width: 1.4),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppleMusicColors.textPrimary,
      linearTrackColor: Color(0x33FFFFFF),
      circularTrackColor: Color(0x33FFFFFF),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0x14FFFFFF),
      selectedColor: const Color(0x26FFFFFF),
      surfaceTintColor: Colors.transparent,
      side: const BorderSide(color: Color(0x1FFFFFFF)),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      labelStyle: typography.white.labelMedium,
      secondaryLabelStyle: typography.white.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    listTileTheme: ListTileThemeData(
      textColor: AppleMusicColors.textPrimary,
      iconColor: AppleMusicColors.textSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: AppleMusicColors.textPrimary,
      unselectedLabelColor: AppleMusicColors.textTertiary,
      indicatorColor: AppleMusicColors.textPrimary,
      dividerColor: AppleMusicColors.hairline,
      labelStyle: typography.white.labelLarge,
      unselectedLabelStyle: typography.white.labelLarge,
    ),
  );
}
