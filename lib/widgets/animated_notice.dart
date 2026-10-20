import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import 'accessible_controls.dart';

/// An inline, dismissible error strip. Material 3 error-container tones keep
/// it legible on both the lyric canvas and a dialog surface.
class AnimatedNotice extends StatelessWidget {
  const AnimatedNotice({super.key, required this.message, this.onDismiss});

  final String? message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : AppMotion.standard,
      switchInCurve: AppMotion.emphasizedDecelerate,
      switchOutCurve: AppMotion.emphasizedAccelerate,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.topLeft,
            child: FadeTransition(opacity: animation, child: child),
          ),
      child: message == null
          ? const SizedBox.shrink(key: ValueKey<String>('none'))
          : Container(
              key: ValueKey<String>(message!),
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: AppShape.mdRadius,
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TrText(
                      message!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                  ),
                  if (onDismiss != null)
                    AccessibleIconButton(
                      tooltip: '关闭提示',
                      color: scheme.onErrorContainer,
                      onPressed: onDismiss,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                ],
              ),
            ),
    );
  }
}
