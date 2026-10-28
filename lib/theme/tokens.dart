import 'package:flutter/material.dart';

/// Typography families bundled with the app.
///
/// MiSans is the UI face on every platform: it has the CJK coverage the
/// catalogue needs, and it is hinted + antialiased on Windows, macOS and
/// Linux. The fallbacks only cover exotic glyphs MiSans lacks.
abstract final class AppFonts {
  static const String sans = 'MiSans';
  static const List<String> sansFallback = <String>[
    'Segoe UI',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'sans-serif',
  ];

  /// Serif role — kept for cover-art lyric exports only; the interface itself
  /// is one sans family.
  static const String serif = 'MiSans';
  static const List<String> serifFallback = <String>[
    'Georgia',
    'Microsoft YaHei',
    'serif',
  ];

  /// Monospace role — MiSans first so timecodes match the rest of the chrome.
  static const String mono = 'MiSans';
  static const List<String> monoFallback = <String>[
    'Consolas',
    'Courier New',
    'monospace',
  ];
}

/// Material 3 shape scale used by the whole interface. One radius vocabulary
/// avoids the old mix of 8/11/12/14/15/16/18/24/28 dp corners.
abstract final class AppShape {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  static const BorderRadius xsRadius = BorderRadius.all(Radius.circular(xs));
  static const BorderRadius smRadius = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgRadius = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlRadius = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlRadius = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius full = BorderRadius.all(Radius.circular(999));
}

/// Shared motion tokens — the single source for every duration and curve.
///
/// EdLazer motion style: crisp and quick. Mostly fades, very little travel,
/// no overshoot. Everything is driven by vsync (AnimationController / Ticker /
/// implicit animations); nothing animates from a [Timer].
abstract final class AppMotion {
  /// Hover, press, toggles.
  static const Duration instant = Duration(milliseconds: 100);

  /// Small state changes: icons, chips, colour fades.
  static const Duration quick = Duration(milliseconds: 150);

  /// Default for fades, cross-fades and page switches.
  static const Duration standard = Duration(milliseconds: 200);

  /// Largest movement in the app: sheets, the player opening.
  static const Duration emphasized = Duration(milliseconds: 250);

  /// Exits are a touch faster than entrances.
  static const Duration exit = Duration(milliseconds: 180);

  /// Page / section switches inside the shell.
  static const Duration page = standard;

  /// Cover art and backdrop palette cross-fades.
  static const Duration crossFade = standard;

  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Curves.easeOutCubic;
  static const Curve fadeCurve = Curves.easeOut;
  static const Curve inOutCurve = Curves.easeInOut;

  /// Entering / leaving properties. Kept as names for older call sites; both
  /// are plain eases now (no M3 "expressive" overshoot-like tails).
  static const Curve emphasizedDecelerate = Curves.easeOutCubic;
  static const Curve emphasizedAccelerate = Curves.easeInCubic;
  static const Curve exitCurve = Curves.easeInCubic;

  /// Tiny vertical travel used together with a fade (fraction of height).
  static const double pageSlide = .012;

  /// Duration honouring the platform's reduce-motion switch.
  static Duration of(BuildContext context, Duration duration) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? Duration.zero
      : duration;

  /// The frame-time overlay's reference budget (diagnostics only).
  static const double frameBudgetMs = 1000 / 100;
}

/// The design tokens the shell is built from.
///
/// The palette is the Lazer blue-grey: lake blue by day, pale ice blue at
/// night, warm paper neutrals and a clay tertiary. It is a complete Material 3
/// role set — every surface role has an explicit tone, so no widget can fall
/// back to Flutter's purple baseline scheme.
class LegacyTokens {
  const LegacyTokens._();

  // Light neutrals.
  static const Color paper = Color(0xFFF7F5EF);
  static const Color paperRaised = Color(0xFFFCFAF5);
  static const Color paperContainer = Color(0xFFF0ECE3);
  static const Color ink = Color(0xFF1B2A30);
  static const Color quietInk = Color(0xFF5B6B71);

  // Brand hues.
  static const Color lakeBlue = Color(0xFF5F91AC);
  static const Color deepBlue = Color(0xFF365F73);
  static const Color warmClay = Color(0xFFB88769);

  // Dark neutrals.
  static const Color nightPaper = Color(0xFF141C20);
  static const Color nightRaised = Color(0xFF1A2327);
  static const Color nightContainer = Color(0xFF1E282C);
  static const Color nightInk = Color(0xFFE2E8E9);
  static const Color nightQuietInk = Color(0xFFB7C3C7);
  static const Color nightBlue = Color(0xFF9CCDE4);

  /// Rail width and page padding the desktop shell uses.
  static const double railWidth = 208;
  static const double pagePadding = 28;
  static const double playerBarHeight = 84;
  static const double compactPlayerBarHeight = 64;
}
