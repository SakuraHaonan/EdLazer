import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../motion/ed_motion.dart';
import '../theme/apple_design.dart';
import '../theme/tokens.dart';

/// Shape and spacing of the floating liquid-glass chrome.
///
/// On a phone the mini player and the tab bar are two separate capsules with
/// a visible gap. Desktop uses the same material for the transport capsule.
///
/// The material itself is `liquid_glass_renderer` 1.0.0-dev.2 (Apache-2.0,
/// whynotmake.it): an iOS 27 bevel that refracts the backdrop. See
/// `docs/liquid-glass.md`.
abstract final class LiquidGlassMetrics {
  /// Corner radius of the floating panels. On the short phone capsules this
  /// is nearly a stadium, which is the shape of the system tab bar.
  static const double radius = AppShape.xxl;

  /// Gap between a panel and the window's side edges.
  static const double sideMargin = 12;

  /// Visible gap between the phone's music capsule and the navigation capsule.
  ///
  /// The page shows through this strip. The capsules are not one blended card.
  static const double barGap = 10;

  /// Gap under the lowest panel when the platform reports no bottom inset.
  static const double bottomMargin = 10;

  /// Height of the tab row.
  static const double navHeight = 56;

  /// Breathing room between the last scrolled row and the top capsule.
  static const double contentGap = 12;

  /// Distance from the window's bottom edge to the bottom of the lowest
  /// floating panel: the system inset when there is one, a small margin
  /// otherwise.
  static double bottomGap(BuildContext context) {
    final double safe = MediaQuery.paddingOf(context).bottom;
    return safe > 0 ? safe : bottomMargin;
  }
}

/// How much of a page's bottom edge sits under the floating capsules.
class FloatingDockInset extends InheritedWidget {
  const FloatingDockInset({
    super.key,
    required this.inset,
    required super.child,
  });

  final double inset;

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

/// iOS 27 regular glass, the preset the renderer fits to toolbars and tab bars.
///
/// Slider position 0 keeps the backdrop visible and the bevel refractive.
/// High contrast uses the tinted end of the same preset so labels stay readable.
LiquidGlassSettings liquidGlassSettings(
  BuildContext context, {
  bool lens = false,
}) {
  if (lens) return _lensSettings;
  final bool contrast = MediaQuery.highContrastOf(context);
  final Brightness brightness = Theme.of(context).brightness;
  return LiquidGlassSettings.ios27Regular(
    brightness: brightness,
    tintAmount: contrast ? 1 : 0,
  );
}

LiquidGlassAppearance liquidGlassAppearance(BuildContext context) {
  return LiquidGlassAppearance.ios27Regular(
    brightness: Theme.of(context).brightness,
  );
}

/// The tab-bar loupe from the renderer's example: a clear lens that shows
/// the surface slightly smaller and bends color along the rim.
///
/// Adapted from `LoupeTabBar.defaultLoupeSettings` in
/// `liquid_glass_renderer` 1.0.0-dev.2. The selection slides on EdLazer's
/// critically damped curve; the example's bouncy loupe spring is not used.
const LiquidGlassSettings _lensSettings = LiquidGlassSettings(
  refractionHeight: 15,
  refractionAmount: 10,
  refractionFitsShape: false,
  dispersion: -0.3,
  frost: 0,
  contourStrength: 0.3,
  backdropShrink: 0.14,
);

const List<BoxShadow> _glassShadows = <BoxShadow>[
  BoxShadow(color: Color(0x24000000), blurRadius: 24, offset: Offset(0, 8)),
];

/// Shared backdrop for sibling [LiquidGlassPanel]s.
///
/// The phone dock puts the music capsule and the tab capsule in one layer so
/// they sample the page once. They are not a blend group, so the gap between
/// them stays open.
class LiquidGlassChrome extends StatelessWidget {
  const LiquidGlassChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassLayer(
      settings: liquidGlassSettings(context),
      defaultAppearance: liquidGlassAppearance(context),
      useBackdropGroup: true,
      child: child,
    );
  }
}

/// One floating liquid-glass capsule.
///
/// Delegates the optics to [LiquidGlass.withOwnLayer]. Where Impeller and
/// Flutter GPU are on, the rim refracts the backdrop. Otherwise the package
/// paints its own [FakeGlass] fallback, which keeps the silhouette and drops
/// the bend.
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

  @override
  Widget build(BuildContext context) {
    final double radius = borderRadius
        .resolve(Directionality.of(context))
        .topLeft
        .x;
    return LiquidGlass.auto(
      settings: liquidGlassSettings(context),
      appearance: liquidGlassAppearance(context),
      shape: LiquidRoundedSuperellipse(borderRadius: radius),
      shadows: _glassShadows,
      useBackdropGroup: true,
      child: child,
    );
  }
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

/// The phone tab row inside a [LiquidGlassPanel].
///
/// The selected tab is a clear loupe ([_lensSettings]) on its own glass
/// layer, so it refracts the capsule under it. It glides on the critically
/// damped chrome curve. Icons cross-fade. Nothing overshoots.
class LiquidGlassNavBar extends StatelessWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.destinations,
    required this.onDestinationSelected,
  });

  static const Key selectionKey = ValueKey<String>('liquid-glass-selection');

  final int selectedIndex;
  final List<LiquidGlassDestination> destinations;
  final ValueChanged<int> onDestinationSelected;

  static const Duration _slide = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
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
                  left: itemWidth * index,
                  top: 0,
                  bottom: 0,
                  width: itemWidth,
                  child: IgnorePointer(
                    child: LiquidGlass.withOwnLayer(
                      key: selectionKey,
                      settings: liquidGlassSettings(context, lens: true),
                      appearance: const LiquidGlassAppearance.ios27Clear(),
                      shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                      child: const SizedBox.expand(),
                    ),
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
                          color: apple.label.withValues(alpha: .86),
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
        hoverColor: Colors.transparent,
        focusColor: Colors.transparent,
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
