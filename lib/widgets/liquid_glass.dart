import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../motion/ed_motion.dart';
import '../theme/apple_design.dart';
import '../theme/tokens.dart';

/// Shape and spacing of the floating "liquid glass" chrome at the bottom of
/// the main window: the phone dock (mini player + tabs) and the desktop
/// transport capsule.
abstract final class LiquidGlassMetrics {
  /// Corner radius of the floating panels.
  static const double radius = AppShape.xxl;

  /// Gap between the panel and the window's side edges.
  static const double sideMargin = 12;

  /// Gap under the panel when the platform reports no bottom inset.
  static const double bottomMargin = 10;

  /// Height of the tab row inside the phone dock.
  static const double navHeight = 56;

  /// Backdrop blur strength. One Gaussian per panel; never nested.
  static const double blurSigma = 24;

  /// Saturation boost applied to the blurred backdrop (1 = unchanged).
  static const double saturation = 1.5;

  /// Breathing room between the last scrolled row and the panel's top edge.
  static const double contentGap = 12;

  /// Distance from the window's bottom edge to the bottom of a floating
  /// panel: the system inset when there is one, a small margin otherwise.
  static double bottomGap(BuildContext context) {
    final double safe = MediaQuery.paddingOf(context).bottom;
    return safe > 0 ? safe : bottomMargin;
  }
}

/// How much of a page's bottom edge sits under a floating panel.
///
/// The shell lets pages run to the window's bottom edge so they scroll under
/// the glass; scrolling pages read this to end their content above it.
class FloatingDockInset extends InheritedWidget {
  const FloatingDockInset({
    super.key,
    required this.inset,
    required super.child,
  });

  final double inset;

  /// The inset at [context], or zero outside a floating-dock shell.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FloatingDockInset>()?.inset ??
      0;

  @override
  bool updateShouldNotify(FloatingDockInset oldWidget) =>
      oldWidget.inset != inset;
}

/// A sliver spacer that ends a [CustomScrollView] above the floating dock.
class FloatingDockSpacer extends StatelessWidget {
  const FloatingDockSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    final double inset = FloatingDockInset.of(context);
    return SliverToBoxAdapter(child: SizedBox(height: inset));
  }
}

/// A floating, translucent Apple-style "liquid glass" panel.
///
/// One clipped [BackdropFilter] (blur + a cheap saturation matrix) under a
/// theme-aware tint, a top-lit sheen, and a gradient rim that is brightest
/// along the top edge. The soft shadow is painted outside the clip. The whole
/// panel is its own repaint boundary so the controls inside it never force
/// the page under it to repaint, and vice versa.
class LiquidGlassPanel extends StatelessWidget {
  const LiquidGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(LiquidGlassMetrics.radius),
    ),
  });

  final Widget child;
  final BorderRadius borderRadius;

  static final ui.ImageFilter _filter = ui.ImageFilter.compose(
    outer: ui.ColorFilter.matrix(
      _saturationMatrix(LiquidGlassMetrics.saturation),
    ),
    inner: ui.ImageFilter.blur(
      sigmaX: LiquidGlassMetrics.blurSigma,
      sigmaY: LiquidGlassMetrics.blurSigma,
      tileMode: TileMode.clamp,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final _GlassStyle style = dark ? _GlassStyle.dark : _GlassStyle.light;
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: style.shadows,
        ),
        child: ClipRRect(
          borderRadius: borderRadius,
          child: BackdropFilter(
            filter: _filter,
            child: CustomPaint(
              painter: _GlassBodyPainter(style: style, radius: borderRadius),
              foregroundPainter: _GlassRimPainter(
                style: style,
                radius: borderRadius,
              ),
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// Standard luminance-preserving saturation matrix.
List<double> _saturationMatrix(double s) {
  const double r = 0.2126, g = 0.7152, b = 0.0722;
  final double i = 1 - s;
  return <double>[
    r * i + s, g * i, b * i, 0, 0, //
    r * i, g * i + s, b * i, 0, 0, //
    r * i, g * i, b * i + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

@immutable
class _GlassStyle {
  const _GlassStyle({
    required this.tintTop,
    required this.tintBottom,
    required this.sheen,
    required this.rimTop,
    required this.rimBottom,
    required this.shadows,
  });

  final Color tintTop;
  final Color tintBottom;
  final Color sheen;
  final Color rimTop;
  final Color rimBottom;
  final List<BoxShadow> shadows;

  static const _GlassStyle light = _GlassStyle(
    tintTop: Color(0xA3FFFFFF),
    tintBottom: Color(0x85F4F5F8),
    sheen: Color(0x73FFFFFF),
    rimTop: Color(0xF2FFFFFF),
    rimBottom: Color(0x40FFFFFF),
    shadows: <BoxShadow>[
      BoxShadow(
        color: Color(0x1A000000),
        blurRadius: 24,
        offset: Offset(0, 6),
      ),
      BoxShadow(color: Color(0x0F000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  static const _GlassStyle dark = _GlassStyle(
    tintTop: Color(0x8C2C2C30),
    tintBottom: Color(0xA61A1A1D),
    sheen: Color(0x1AFFFFFF),
    rimTop: Color(0x52FFFFFF),
    rimBottom: Color(0x0FFFFFFF),
    shadows: <BoxShadow>[
      BoxShadow(
        color: Color(0x59000000),
        blurRadius: 26,
        offset: Offset(0, 8),
      ),
      BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 1)),
    ],
  );
}

class _GlassBodyPainter extends CustomPainter {
  const _GlassBodyPainter({required this.style, required this.radius});

  final _GlassStyle style;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect shape = radius.toRRect(rect);
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[style.tintTop, style.tintBottom],
        ).createShader(rect),
    );
    // Top-lit sheen: a soft band of light that fades out before the middle,
    // the "liquid" highlight that sits on the upper lip of the glass.
    final double sheenHeight = size.height.clamp(0, 64) * .6;
    final Rect sheenRect = Rect.fromLTWH(0, 0, size.width, sheenHeight);
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[style.sheen, style.sheen.withValues(alpha: 0)],
        ).createShader(sheenRect),
    );
  }

  @override
  bool shouldRepaint(_GlassBodyPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.radius != radius;
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({required this.style, required this.radius});

  final _GlassStyle style;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect rim = radius.toRRect(rect).deflate(.5);
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[style.rimTop, style.rimBottom, style.rimBottom],
          stops: const <double>[0, .55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.radius != radius;
}

/// One destination of a [LiquidGlassNavBar].
@immutable
class LiquidGlassDestination {
  const LiquidGlassDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// The tab row of the phone dock. It paints no glass of its own — it sits
/// inside a [LiquidGlassPanel] — only the selected-tab pill, a lighter lens
/// of glass that glides between tabs on the chrome's critically damped curve
/// (no overshoot).
class LiquidGlassNavBar extends StatelessWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final List<LiquidGlassDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  static const Duration _slide = Duration(milliseconds: 240);

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Duration duration = EdMotion.durationOf(context, _slide);
    final TextStyle base =
        (Theme.of(context).textTheme.labelSmall ?? const TextStyle()).copyWith(
          fontSize: 10.5,
          height: 1.1,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
        );
    return SizedBox(
      height: LiquidGlassMetrics.navHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final int count = destinations.length;
            final double itemWidth = constraints.maxWidth / count;
            final int index = selectedIndex.clamp(0, count - 1);
            return Stack(
              children: <Widget>[
                AnimatedPositioned(
                  duration: duration,
                  curve: EdMotion.curve,
                  left: itemWidth * index + 2,
                  top: 0,
                  bottom: 0,
                  width: itemWidth - 4,
                  child: IgnorePointer(child: _SelectionPill(dark: dark)),
                ),
                Row(
                  children: <Widget>[
                    for (int i = 0; i < count; i++)
                      Expanded(
                        child: _NavItem(
                          destination: destinations[i],
                          selected: i == index,
                          duration: duration,
                          selectedColor: apple.accent,
                          color: apple.label.withValues(alpha: .78),
                          style: base,
                          onTap: () => onDestinationSelected(i),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SelectionPill extends StatelessWidget {
  const _SelectionPill({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppShape.full,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const <Color>[Color(0x2EFFFFFF), Color(0x14FFFFFF)]
              : const <Color>[Color(0xD9FFFFFF), Color(0x8CFFFFFF)],
        ),
        border: Border.all(
          color: dark ? const Color(0x2EFFFFFF) : const Color(0xFFFFFFFF),
          width: .8,
        ),
        boxShadow: dark
            ? null
            : const <BoxShadow>[
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.duration,
    required this.selectedColor,
    required this.color,
    required this.style,
    required this.onTap,
  });

  final LiquidGlassDestination destination;
  final bool selected;
  final Duration duration;
  final Color selectedColor;
  final Color color;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color tint = selected ? selectedColor : color;
    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
        hoverColor: color.withValues(alpha: .06),
        focusColor: selectedColor.withValues(alpha: .14),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: Icon(
                selected ? destination.selectedIcon : destination.icon,
                key: ValueKey<bool>(selected),
                size: 23,
                color: tint,
              ),
            ),
            const SizedBox(height: 2),
            AnimatedDefaultTextStyle(
              duration: duration,
              curve: Curves.easeOut,
              style: style.copyWith(color: tint),
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.fade,
                softWrap: false,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
