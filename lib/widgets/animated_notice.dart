import 'package:lazer_nextgen/theme/app_palette.dart';

import '../l10n/app_localizations.dart';
import '../motion/ed_motion.dart';
import 'accessible_controls.dart';

import 'package:flutter/material.dart';

class AnimatedNotice extends StatelessWidget {
  const AnimatedNotice({super.key, required this.message, this.onDismiss});
  final String? message;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: EdMotion.durationOf(context, EdMotion.entranceDuration),
    switchInCurve: EdMotion.curve,
    switchOutCurve: EdMotion.curve,
    transitionBuilder: (Widget child, Animation<double> animation) =>
        FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, EdMotion.travel),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
    child: message == null
        ? const SizedBox.shrink(key: ValueKey('none'))
        : Padding(
            key: ValueKey(message),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TrText(
                    message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodySm.copyWith(
                      color: context.colors.clayDeep,
                      fontSize: 14,
                    ),
                  ),
                ),
                if (onDismiss != null)
                  AccessibleIconButton(
                    tooltip: '关闭提示',
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close_rounded, size: 16),
                  ),
              ],
            ),
          ),
  );
}
