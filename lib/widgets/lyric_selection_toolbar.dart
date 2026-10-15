import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/design_tokens.dart';
import 'accessible_controls.dart';

class LyricSelectionToolbar extends StatelessWidget {
  const LyricSelectionToolbar({
    super.key,
    required this.count,
    required this.copied,
    required this.onSelectAll,
    required this.onCopy,
    required this.onClose,
  });
  final int count;
  final bool copied;
  final VoidCallback onSelectAll;
  final VoidCallback onCopy;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.ivoryLight,
    shape: const Border.fromBorderSide(AppBorders.hairline),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: TrText(
                copied ? '已复制' : '已选择 $count 行',
                key: ValueKey(copied),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.captionStrong,
              ),
            ),
          ),
          AccessibleIconButton(
            tooltip: '全选',
            onPressed: onSelectAll,
            icon: const Icon(Icons.select_all_rounded, size: 21),
          ),
          AccessibleIconButton(
            tooltip: '复制所选歌词',
            onPressed: onCopy,
            icon: Icon(
              copied ? Icons.check_rounded : Icons.content_copy_rounded,
              size: 20,
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
