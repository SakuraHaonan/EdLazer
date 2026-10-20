import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import 'accessible_controls.dart';

/// Selection actions for the lyric sheet.
///
/// A Material 3 tonal surface floating over the lyrics: the count animates,
/// the actions sit on 48 dp targets and the whole bar respects reduced motion.
class LyricSelectionToolbar extends StatelessWidget {
  const LyricSelectionToolbar({
    super.key,
    required this.count,
    required this.copied,
    required this.onSelectAll,
    required this.onCopy,
    required this.onCreateImage,
    required this.onClose,
  });

  final int count;
  final bool copied;
  final VoidCallback onSelectAll;
  final VoidCallback onCopy;
  final VoidCallback onCreateImage;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Material(
      color: scheme.surfaceContainerHigh,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppShape.xlRadius),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
        child: Row(
          children: <Widget>[
            Expanded(
              child: AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : AppMotion.standard,
                switchInCurve: AppMotion.emphasizedDecelerate,
                switchOutCurve: AppMotion.emphasizedAccelerate,
                transitionBuilder:
                    (Widget child, Animation<double> animation) =>
                        FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, .2),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                child: TrText(
                  copied ? '已复制' : '已选择 $count 行',
                  key: ValueKey<(bool, int)>((copied, count)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            AccessibleIconButton(
              tooltip: '全选',
              onPressed: onSelectAll,
              icon: const Icon(Icons.select_all_rounded, size: 21),
            ),
            AccessibleIconButton(
              tooltip: '生成歌词图片',
              color: scheme.primary,
              onPressed: onCreateImage,
              icon: const Icon(Icons.image_outlined, size: 21),
            ),
            AccessibleIconButton(
              tooltip: '复制所选歌词',
              onPressed: onCopy,
              icon: AnimatedSwitcher(
                duration: reduceMotion ? Duration.zero : AppMotion.quick,
                switchInCurve: AppMotion.emphasizedDecelerate,
                switchOutCurve: AppMotion.emphasizedAccelerate,
                transitionBuilder:
                    (Widget child, Animation<double> animation) =>
                        FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: .75,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                child: Icon(
                  copied ? Icons.check_rounded : Icons.content_copy_rounded,
                  key: ValueKey<bool>(copied),
                  size: 20,
                ),
              ),
            ),
            AccessibleIconButton(
              tooltip: '关闭',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 21),
            ),
          ],
        ),
      ),
    );
  }
}
