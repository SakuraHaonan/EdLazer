import 'package:flutter/material.dart';

import 'design_tokens.dart';

@immutable
class AppPalette {
  const AppPalette(this.dark);
  final bool dark;
  static AppPalette of(BuildContext context) =>
      AppPalette(Theme.of(context).brightness == Brightness.dark);
  Color get slateDark => dark ? const Color(0xFFF0EEE6) : AppColors.slateDark;
  Color get ivoryMedium =>
      dark ? const Color(0xFF191918) : AppColors.ivoryMedium;
  Color get ivoryLight => dark ? const Color(0xFF242423) : AppColors.ivoryLight;
  Color get cloudMedium =>
      dark ? const Color(0xFFA8A69E) : AppColors.cloudMedium;
  Color get cloudDark => dark ? const Color(0xFFB5B2A9) : AppColors.cloudDark;
  Color get stone => dark ? const Color(0xFF454540) : AppColors.stone;
  Color get slateMedium =>
      dark ? const Color(0xFF454540) : AppColors.slateMedium;
  Color get oatWarm => dark ? const Color(0xFF34312D) : AppColors.oatWarm;
  Color get manilla => dark ? const Color(0xFF3E3329) : AppColors.manilla;
  Color get clay => dark ? const Color(0xFFE68E70) : AppColors.clay;
  Color get clayDeep => dark ? const Color(0xFFF0A084) : AppColors.clayDeep;
  Color get onDark => AppColors.onDark;
  Color get onDarkMuted => AppColors.onDarkMuted;

  /// Content sitting on a [slateDark] fill, which flips to paper in dark mode.
  Color get onInk => dark ? AppColors.slateDark : AppColors.onDark;
  Color get playerSurface => const Color(0xFF141413);
  Color get onPlayer => AppColors.onDark;
}

class AppTypography {
  const AppTypography(this.colors);
  final AppPalette colors;
  TextStyle _main(TextStyle style) => style.copyWith(color: colors.slateDark);
  TextStyle _muted(TextStyle style) =>
      style.copyWith(color: colors.cloudMedium);
  TextStyle get caption => _main(AppText.caption);
  TextStyle get captionMuted => _muted(AppText.captionMuted);
  TextStyle get captionStrong => _main(AppText.captionStrong);
  TextStyle get bodySm => _main(AppText.bodySm);
  TextStyle get bodySmMuted => _muted(AppText.bodySmMuted);
  TextStyle get body => _main(AppText.body);
  TextStyle get bodyMuted =>
      AppText.bodyMuted.copyWith(color: colors.cloudDark);
  TextStyle get subheading => _main(AppText.subheading);
  TextStyle get heading => _main(AppText.heading);
  TextStyle get display => _main(AppText.display);
  TextStyle get mono => _main(AppText.mono);
  TextStyle get monoSm => AppText.monoSm.copyWith(color: colors.cloudDark);
  TextStyle get wordmark => _main(AppText.wordmark);
}

class AppBorderPalette {
  const AppBorderPalette(this.colors);
  final AppPalette colors;
  BorderSide get hairline => BorderSide(color: colors.stone);
  BorderSide get hairlineDark => BorderSide(color: colors.slateDark);
  BorderSide get onDark => BorderSide(color: colors.slateMedium);
  BorderSide get outlined => BorderSide(color: colors.cloudDark);
}

extension AppAppearance on BuildContext {
  AppPalette get colors => AppPalette.of(this);
  AppTypography get type => AppTypography(colors);
  AppBorderPalette get borders => AppBorderPalette(colors);
}
