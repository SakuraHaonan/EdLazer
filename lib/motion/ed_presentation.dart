import 'package:flutter/material.dart';

import 'ed_motion.dart';

/// Dialog entrance: fade-through on the shared vertical axis.
///
/// Material's default dialog scales from the center, which resamples text for
/// the whole transition. This only fades and translates, both as compositor
/// layers, on [EdMotion.curve].
Future<T?> edShowDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
  Offset? anchorPoint,
}) {
  final bool reduced = EdMotion.reducedOf(context);
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: useRootNavigator).context,
  );
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel:
        barrierLabel ??
        MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: barrierColor ?? const Color(0x8A000000),
    transitionDuration: reduced ? Duration.zero : EdMotion.throughDuration,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    anchorPoint: anchorPoint,
    pageBuilder:
        (
          BuildContext dialogContext,
          Animation<double> animation,
          Animation<double> secondary,
        ) {
          return Builder(
            builder: (BuildContext context) =>
                themes.wrap(builder(dialogContext)),
          );
        },
    transitionBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondary,
          Widget child,
        ) {
          final Animation<double> eased = CurvedAnimation(
            parent: animation,
            curve: EdMotion.curve,
            reverseCurve: EdMotion.curve,
          );
          return FadeTransition(
            opacity: eased,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, EdMotion.travel),
                end: Offset.zero,
              ).animate(eased),
              child: RepaintBoundary(child: child),
            ),
          );
        },
  );
}

/// Bottom sheet on the same spring as the now-playing sheet.
///
/// The framework still owns the drag (so fling-to-dismiss keeps working).
/// The open and close sample [EdMotion.curve] instead of the Material ease.
Future<T?> edShowSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
  bool showDragHandle = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  ShapeBorder? shape,
}) {
  final bool reduced = EdMotion.reducedOf(context);
  final Duration duration = reduced ? Duration.zero : EdMotion.settleDuration;
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor,
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    shape: shape,
    sheetAnimationStyle: AnimationStyle(
      duration: duration,
      reverseDuration: duration,
      curve: EdMotion.curve,
      reverseCurve: EdMotion.curve,
    ),
  );
}
