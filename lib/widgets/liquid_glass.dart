import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../motion/ed_motion.dart';
import '../theme/apple_design.dart';
import '../theme/tokens.dart';

/// Shape and spacing of the floating liquid-glass chrome.
///
/// On a phone the mini player and the tab bar are two separate capsules with
/// a visible gap. Desktop uses the same material for the transport capsule.
abstract final class LiquidGlassMetrics {
  /// Corner radius of the floating panels. On the short phone capsules this
  /// is nearly a stadium, which is the shape of the system tab bar.
  static const double radius = AppShape.xxl;

  /// Gap between a panel and the window's side edges.
  static const double sideMargin = 12;

  /// Visible gap between the phone's music capsule and the navigation capsule.
  ///
  /// The page shows through this strip. It is not a divider drawn on one
  /// shared card.
  static const double barGap = 10;

  /// Gap under the lowest panel when the platform reports no bottom inset.
  static const double bottomMargin = 10;

  /// Height of the tab row.
  static const double navHeight = 56;

  /// Backdrop blur used where the refraction shader cannot run.
  static const double blurSigma = 18;

  /// Softer blur placed under the refraction shader so the bend reads as
  /// glass rather than a hard lens.
  static const double refractiveBlurSigma = 8;

  /// Saturation boost applied to the blurred backdrop (1 = unchanged).
  static const double saturation = 1.35;

  /// Breathing room between the last scrolled row and the top capsule.
  static const double contentGap = 12;

  /// How far a refraction may shove backdrop pixels, in logical pixels.
  static const double refraction = 7;

  /// Width of the rim that is allowed to bend, in logical pixels.
  static const double bezel = 14;

  /// Distance from the window's bottom edge to the bottom of the lowest
  /// floating panel: the system inset when there is one, a small margin
  /// otherwise.
  static double bottomGap(BuildContext context) {
    final double safe = MediaQuery.paddingOf(context).bottom;
    return safe > 0 ? safe : bottomMargin;
  }
}

/// How much of a page's bottom edge sits under the floating capsules.
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

/// Loads the refraction shader once. A failure leaves [program] null and the
/// panels use the blur fallback.
abstract final class LiquidGlassProgram {
  static ui.FragmentProgram? program;
  static bool failed = false;
  static Future<void>? _loading;

  static Future<void> ensure() {
    if (program != null || failed) return Future<void>.value();
    return _loading ??= () async {
      try {
        program = await ui.FragmentProgram.fromAsset(
          'shaders/liquid_glass.frag',
        );
      } catch (_) {
        failed = true;
        program = null;
      }
    }();
  }
}

/// A floating liquid-glass panel.
///
/// This is an approximation of Apple's Liquid Glass, not the system material.
/// Where Impeller accepts [ui.ImageFilter.shader], the backdrop is blurred,
/// then a fragment shader bends pixels along the rim, splits a little color,
/// and lays down a thin adaptive veil. The specular rim and the top sheen are
/// painted in both paths so Skia and Impeller share one edge treatment.
///
/// Where the shader cannot run, the same silhouette is a clipped blur, a
/// saturation lift, the same thin veil, and the same light rim. There is no
/// dark card border. The shadow is punched out of the panel's own bounds so
/// the glass does not sample its shadow and turn grey.
class LiquidGlassPanel extends StatefulWidget {
  const LiquidGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(LiquidGlassMetrics.radius),
    ),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<LiquidGlassPanel> createState() => _LiquidGlassPanelState();
}

class _LiquidGlassPanelState extends State<LiquidGlassPanel> {
  Rect? _deviceRect;
  bool _measureQueued = false;
  ui.FragmentShader? _shader;

  @override
  void initState() {
    super.initState();
    if (LiquidGlassProgram.program == null && !LiquidGlassProgram.failed) {
      unawaited(
        LiquidGlassProgram.ensure().then((_) {
          if (mounted) setState(() {});
        }),
      );
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  void _scheduleMeasure() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (!mounted) return;
      final RenderObject? object = context.findRenderObject();
      if (object is! RenderBox || !object.hasSize || !object.attached) return;
      final double dpr = MediaQuery.devicePixelRatioOf(context);
      final Rect next = _quantize(
        (object.localToGlobal(Offset.zero) * dpr) & (object.size * dpr),
      );
      if (next == _deviceRect) return;
      setState(() => _deviceRect = next);
    });
  }

  Rect _quantize(Rect rect) => Rect.fromLTRB(
    (rect.left * 2).roundToDouble() / 2,
    (rect.top * 2).roundToDouble() / 2,
    (rect.right * 2).roundToDouble() / 2,
    (rect.bottom * 2).roundToDouble() / 2,
  );

  ui.FragmentShader _ownedShader() =>
      _shader ??= LiquidGlassProgram.program!.fragmentShader();

  ui.ImageFilter _filter({
    required bool dark,
    required bool contrast,
    required double dpr,
  }) {
    final ui.ImageFilter frost = _frostFilter(contrast: contrast);
    final ui.FragmentProgram? program = LiquidGlassProgram.program;
    final Rect? rect = _deviceRect;
    if (contrast ||
        program == null ||
        rect == null ||
        !ui.ImageFilter.isShaderFilterSupported) {
      return frost;
    }
    try {
      final ui.FragmentShader shader = _ownedShader();
      final double radius =
          widget.borderRadius.resolve(Directionality.of(context)).topLeft.x *
          dpr;
      var index = 2;
      for (final double value in <double>[
        rect.left,
        rect.top,
        rect.width,
        rect.height,
        radius,
        LiquidGlassMetrics.bezel * dpr,
        LiquidGlassMetrics.refraction * dpr,
        dark ? 1 : 0,
      ]) {
        shader.setFloat(index, value);
        index += 1;
      }
      return ui.ImageFilter.compose(
        outer: ui.ImageFilter.shader(shader),
        inner: ui.ImageFilter.blur(
          sigmaX: LiquidGlassMetrics.refractiveBlurSigma,
          sigmaY: LiquidGlassMetrics.refractiveBlurSigma,
          tileMode: TileMode.clamp,
        ),
      );
    } catch (_) {
      return frost;
    }
  }

  bool _usesShader(bool contrast) =>
      !contrast &&
      LiquidGlassProgram.program != null &&
      _deviceRect != null &&
      ui.ImageFilter.isShaderFilterSupported;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool contrast = MediaQuery.highContrastOf(context);
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    if (!contrast && LiquidGlassProgram.program != null) _scheduleMeasure();
    final _GlassStyle style = _GlassStyle.resolve(
      dark: dark,
      contrast: contrast,
    );
    final bool refracting = _usesShader(contrast);
    return RepaintBoundary(
      child: CustomPaint(
        painter: _CutoutShadowPainter(
          radius: widget.borderRadius,
          shadows: style.shadows,
        ),
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: BackdropFilter(
            filter: _filter(dark: dark, contrast: contrast, dpr: dpr),
            child: CustomPaint(
              painter: _GlassBodyPainter(
                style: style,
                radius: widget.borderRadius,
                veil: !refracting,
              ),
              foregroundPainter: _GlassRimPainter(
                style: style,
                radius: widget.borderRadius,
              ),
              child: Material(
                type: MaterialType.transparency,
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

ui.ImageFilter _frostFilter({required bool contrast}) {
  final double sigma = contrast ? 6 : LiquidGlassMetrics.blurSigma;
  return ui.ImageFilter.compose(
    outer: ui.ColorFilter.matrix(
      _saturationMatrix(contrast ? 1 : LiquidGlassMetrics.saturation),
    ),
    inner: ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: TileMode.clamp,
    ),
  );
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
    required this.rimLeading,
    required this.rimTrailing,
    required this.shadows,
  });

  final Color tintTop;
  final Color tintBottom;
  final Color sheen;
  final Color rimLeading;
  final Color rimTrailing;
  final List<BoxShadow> shadows;

  static _GlassStyle resolve({required bool dark, required bool contrast}) {
    if (contrast) {
      return dark ? _GlassStyle.contrastDark : _GlassStyle.contrastLight;
    }
    return dark ? _GlassStyle.dark : _GlassStyle.light;
  }

  static const _GlassStyle light = _GlassStyle(
    tintTop: Color(0x38FFFFFF),
    tintBottom: Color(0x24F4F5F8),
    sheen: Color(0x66FFFFFF),
    rimLeading: Color(0xD9FFFFFF),
    rimTrailing: Color(0x1FFFFFFF),
    shadows: <BoxShadow>[
      BoxShadow(color: Color(0x14000000), blurRadius: 22, offset: Offset(0, 8)),
      BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
    ],
  );

  static const _GlassStyle dark = _GlassStyle(
    tintTop: Color(0x2E1C1C1E),
    tintBottom: Color(0x38101012),
    sheen: Color(0x1AFFFFFF),
    rimLeading: Color(0x73FFFFFF),
    rimTrailing: Color(0x14FFFFFF),
    shadows: <BoxShadow>[
      BoxShadow(
        color: Color(0x40000000),
        blurRadius: 24,
        offset: Offset(0, 10),
      ),
      BoxShadow(color: Color(0x24000000), blurRadius: 3, offset: Offset(0, 1)),
    ],
  );

  static const _GlassStyle contrastLight = _GlassStyle(
    tintTop: Color(0xF7F4F4F6),
    tintBottom: Color(0xF7F4F4F6),
    sheen: Color(0x00000000),
    rimLeading: Color(0xFF8E8E93),
    rimTrailing: Color(0xFF8E8E93),
    shadows: <BoxShadow>[
      BoxShadow(color: Color(0x1F000000), blurRadius: 12, offset: Offset(0, 4)),
    ],
  );

  static const _GlassStyle contrastDark = _GlassStyle(
    tintTop: Color(0xF21C1C1E),
    tintBottom: Color(0xF21C1C1E),
    sheen: Color(0x00000000),
    rimLeading: Color(0xFFAEAEB2),
    rimTrailing: Color(0xFFAEAEB2),
    shadows: <BoxShadow>[
      BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4)),
    ],
  );
}

class _CutoutShadowPainter extends CustomPainter {
  const _CutoutShadowPainter({required this.radius, required this.shadows});

  final BorderRadius radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect shape = radius.toRRect(rect);
    for (final BoxShadow shadow in shadows) {
      final double sigma = shadow.blurRadius <= 0
          ? 0
          : shadow.blurRadius * 0.57735 + 0.5;
      if (sigma <= 0 && shadow.offset == Offset.zero) continue;
      final Rect layer = rect
          .shift(shadow.offset)
          .inflate(shadow.blurRadius * 3 + 8);
      canvas.saveLayer(layer, Paint());
      canvas.drawRRect(
        shape.shift(shadow.offset),
        Paint()
          ..color = shadow.color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma),
      );
      canvas.drawRRect(shape, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_CutoutShadowPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.shadows != shadows;
}

class _GlassBodyPainter extends CustomPainter {
  const _GlassBodyPainter({
    required this.style,
    required this.radius,
    required this.veil,
  });

  final _GlassStyle style;
  final BorderRadius radius;

  /// Whether to paint the tint. The refraction shader already veils the
  /// backdrop, so painting it again would turn the glass back into a card.
  final bool veil;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect shape = radius.toRRect(rect);
    if (veil) {
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[style.tintTop, style.tintBottom],
          ).createShader(rect),
      );
    }
    final double sheenHeight = (size.height * .55).clamp(0, 36);
    if (sheenHeight <= 0 || style.sheen.a == 0) return;
    final Rect sheenRect = Rect.fromLTWH(0, 0, size.width, sheenHeight);
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(
      sheenRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[style.sheen, style.sheen.withValues(alpha: 0)],
        ).createShader(sheenRect),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassBodyPainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.radius != radius ||
      oldDelegate.veil != veil;
}

class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({required this.style, required this.radius});

  final _GlassStyle style;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final RRect rim = radius.toRRect(rect).deflate(.6);
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[style.rimLeading, style.rimTrailing],
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

/// The phone tab row. It paints no glass of its own — it sits inside a
/// [LiquidGlassPanel]. The selected tab is a lighter lens that glides on the
/// chrome's critically damped curve. Icons cross-fade. Nothing overshoots.
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

  static const Duration _slide = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool contrast = MediaQuery.highContrastOf(context);
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
                  child: IgnorePointer(
                    child: _SelectionLens(dark: dark, contrast: contrast),
                  ),
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

class _SelectionLens extends StatelessWidget {
  const _SelectionLens({required this.dark, required this.contrast});

  final bool dark;
  final bool contrast;

  @override
  Widget build(BuildContext context) {
    final Color accent = AppleSemanticColors.of(context).accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: AppShape.full,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: contrast
              ? (dark
                    ? const <Color>[Color(0x55FFFFFF), Color(0x22FFFFFF)]
                    : const <Color>[Color(0xF7FFFFFF), Color(0xD9FFFFFF)])
              : (dark
                    ? const <Color>[Color(0x2EFFFFFF), Color(0x10FFFFFF)]
                    : const <Color>[Color(0xB8FFFFFF), Color(0x66FFFFFF)]),
        ),
        border: contrast ? Border.all(color: accent, width: 1.5) : null,
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
