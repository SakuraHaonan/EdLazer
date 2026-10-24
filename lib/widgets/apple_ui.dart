import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/apple_design.dart';

/// A translucent Apple material: blur plus a semantic glass tint and hairline.
///
/// Used for navigation chrome and transient panels only. Content surfaces stay
/// opaque so text contrast never depends on the artwork behind the window.
class AppleGlass extends StatelessWidget {
  const AppleGlass({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = BorderRadius.zero,
    this.blurSigma = 24,
    this.border,
  });

  final Widget child;
  final Color? color;
  final BorderRadius borderRadius;
  final double blurSigma;
  final Border? border;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Widget material = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color ?? apple.glass,
          borderRadius: borderRadius,
          border: border,
        ),
        child: child,
      ),
    );
    return ClipRRect(borderRadius: borderRadius, child: material);
  }
}

/// Apple large-title page header. It is deliberately independent of
/// [AppBar]: pages scroll under the chrome while their title scrolls away,
/// following the iOS large-title pattern.
class ApplePageTitle extends StatelessWidget {
  const ApplePageTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 8),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    final TextStyle style = (theme.textTheme.displayLarge ?? const TextStyle())
        .copyWith(
          fontSize: compact ? 34 : 32,
          height: (compact ? 41 : 38) / (compact ? 34 : 32),
          fontWeight: FontWeight.w700,
          letterSpacing: .37,
          color: apple.label,
        );
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 5),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 16),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Section heading used by every browse/library/search page.
class AppleSectionHeader extends StatelessWidget {
  const AppleSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(24, 24, 24, 12),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: apple.label,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.4,
                    ),
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 1),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// An inset grouped card, the core of iOS Settings and Music's library lists.
class AppleGroupedCard extends StatelessWidget {
  const AppleGroupedCard({
    super.key,
    required this.child,
    this.margin = const EdgeInsets.symmetric(horizontal: 24),
    this.padding = EdgeInsets.zero,
    this.color,
    this.radius = 14,
  });

  final Widget child;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Container(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? apple.secondaryGroupedBackground,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: apple.separator, width: .5),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// A single list row with Apple's vertical rhythm and press highlight.
class AppleListTile extends StatelessWidget {
  const AppleListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.showChevron = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    this.minHeight = 50,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool showChevron;
  final EdgeInsetsGeometry padding;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Widget row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: padding,
        child: Row(
          children: <Widget>[
            if (leading != null) ...<Widget>[
              leading!,
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: apple.label,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 1),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 12),
              trailing!,
            ],
            if (showChevron) ...<Widget>[
              const SizedBox(width: 8),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: apple.tertiaryLabel,
              ),
            ],
          ],
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return row;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        highlightColor: apple.fill,
        splashFactory: NoSplash.splashFactory,
        child: row,
      ),
    );
  }
}

/// Rounded leading glyph used in library rows and settings account cards.
class AppleIconTile extends StatelessWidget {
  const AppleIconTile({
    super.key,
    required this.icon,
    this.color = AppleColors.musicRed,
    this.size = 30,
    this.iconSize = 17,
    this.radius = 7,
  });

  final IconData icon;
  final Color color;
  final double size;
  final double iconSize;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Color.lerp(color, Colors.white, .15)!,
            color,
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(icon, size: iconSize, color: Colors.white),
    );
  }
}

class AppleEmptyState extends StatelessWidget {
  const AppleEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.music_note_rounded,
    this.action,
  });

  final String message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: apple.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 28, color: apple.secondaryLabel),
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: apple.secondaryLabel,
              ),
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: 18),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// The shell's search input: Material 3's stock [SearchBar], nothing else.
///
/// No custom fill, border or icon tint — the bar takes its shape, color,
/// elevation, focus overlay and text field straight from the Material theme,
/// so it matches any `searchBarTheme` the app installs. The toolbar and the
/// mobile search row only decide how wide and tall it is.
class AppleSearchField extends StatelessWidget {
  const AppleSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.hintText = '搜索歌曲、歌手或歌单',
    this.onClear,
    this.autofocus = false,
    this.height = 56,
    this.textInputAction = TextInputAction.search,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;
  final VoidCallback? onClear;
  final bool autofocus;

  /// How tall the bar draws. 56 is Material's own search bar height.
  final double height;
  final TextInputAction textInputAction;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: SearchBar(
        controller: controller,
        onChanged: onChanged,
        hintText: hintText,
        autoFocus: autofocus,
        // A search field, not a button: no elevation, no shadow and no hover
        // wash. Users who want it will click it.
        elevation: const WidgetStatePropertyAll<double>(0),
        shadowColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        surfaceTintColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
        overlayColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
        textInputAction: textInputAction,
        leading: const Icon(Icons.search),
        // A rounded rectangle rather than Material's default stadium: the bar
        // spans the page width, so a pill would read as a button.
        shape: const WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
        ),
        trailing: <Widget>[
          if (controller.text.isNotEmpty)
            IconButton(
              tooltip: '清除',
              onPressed: onClear,
              icon: const Icon(Icons.close),
            ),
        ],
        // Stock Material reserves 360 px of width; here the toolbar and the
        // mobile row own the width, and the bar fills whatever they give it.
        constraints: BoxConstraints(
          minWidth: 0,
          maxWidth: double.infinity,
          minHeight: height,
          maxHeight: height,
        ),
      ),
    );
  }
}
