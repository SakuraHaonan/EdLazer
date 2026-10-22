import 'package:lazer_nextgen/theme/app_palette.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../widgets/accessible_controls.dart';

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
  Widget build(BuildContext context) => Material(
    color: context.colors.ivoryLight,
    shape: Border.fromBorderSide(context.borders.hairline),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(
                    begin: const Offset(0, .2),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: TrText(
                copied ? '已复制' : '已选择 $count 行',
                key: ValueKey((copied, count)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.type.captionStrong,
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
            color: context.colors.clayDeep,
            onPressed: onCreateImage,
            icon: const Icon(Icons.image_outlined, size: 21),
          ),
          AccessibleIconButton(
            tooltip: '复制所选歌词',
            onPressed: onCopy,
            icon: AnimatedSwitcher(
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: .75, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: Icon(
                copied ? Icons.check_rounded : Icons.content_copy_rounded,
                key: ValueKey(copied),
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
