import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

import 'design_tokens.dart';

/// Builds the [ThemeData] for the parchment system.
///
/// Most surfaces are hand-built from the design tokens rather than leaning on
/// Material defaults, but the theme still sets sane colors, text scaling, and
/// removes Material's elevation shadows so nothing cool-toned or shadowed
/// leaks in from framework defaults.
ThemeData buildAppTheme() {
  const ColorScheme scheme = ColorScheme.light(
    primary: AppColors.clay,
    onPrimary: Colors.white,
    secondary: AppColors.oatWarm,
    onSecondary: AppColors.slateDark,
    surface: AppColors.ivoryLight,
    onSurface: AppColors.slateDark,
    error: AppColors.clayDeep,
    onError: Colors.white,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.ivoryMedium,
    canvasColor: AppColors.ivoryMedium,
    dividerColor: AppColors.stone,
    splashFactory: InkRipple.splashFactory,
    splashColor: AppColors.slateDark.withValues(alpha: 0.09),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
    highlightColor: Colors.transparent,
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(color: AppColors.slateDark),
      textStyle: TextStyle(
        fontFamily: AppFonts.sans,
        color: AppColors.onDark,
        fontSize: 12,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    ),
    // Global safety net: any Text without an explicit AppText style still
    // renders in bundled MiSans instead of the system fallback.
    fontFamily: AppFonts.sans,
    fontFamilyFallback: AppFonts.sansFallback,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: AppColors.clayDeep,
      selectionColor: AppColors.oatWarm,
      selectionHandleColor: AppColors.clayDeep,
    ),
    // Flat everywhere: elevation is expressed through tone, not shadow.
    dialogTheme: const DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      elevation: 0,
      modalElevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.ivoryLight,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.ivoryMedium,
      foregroundColor: AppColors.slateDark,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.clay,
      linearTrackColor: AppColors.oatWarm,
      circularTrackColor: AppColors.oatWarm,
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll<Color>(AppColors.cloudMedium),
      thickness: WidgetStatePropertyAll<double>(8),
      radius: Radius.circular(0),
    ),
  );
}
