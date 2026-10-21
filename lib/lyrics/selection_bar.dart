import 'package:flutter/material.dart';

import '../theme/apple_design.dart';

/// Apple-style floating action bar for lyric selection.
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final ThemeData theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        decoration: BoxDecoration(
          color: apple.glassStrong,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: apple.separator, width: .5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .24),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                transitionBuilder: (Widget child, Animation<double> animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: Text(
                  copied ? '已复制' : '已选择 $count 行',
                  key: ValueKey<bool>(copied),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: apple.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            _Action(
              tooltip: '全选',
              icon: Icons.select_all_rounded,
              onPressed: onSelectAll,
            ),
            _Action(
              tooltip: '生成歌词图片',
              icon: Icons.image_outlined,
              color: apple.accent,
              onPressed: onCreateImage,
            ),
            _Action(
              tooltip: '复制所选歌词',
              icon: copied ? Icons.check_rounded : Icons.copy_rounded,
              onPressed: onCopy,
            ),
            _Action(
              tooltip: '关闭',
              icon: Icons.close_rounded,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 20,
      constraints: const BoxConstraints.tightFor(width: 42, height: 42),
      padding: EdgeInsets.zero,
      color: color ?? apple.secondaryLabel,
      icon: Icon(icon),
    );
  }
}
