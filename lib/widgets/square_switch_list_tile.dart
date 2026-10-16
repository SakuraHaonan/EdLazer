import 'package:flutter/material.dart';

import '../theme/app_palette.dart';
import 'interaction_feedback.dart';

/// An application-rendered rectangular switch; the whole setting remains a
/// single keyboard-focusable, accessible toggle.
class SquareSwitchListTile extends StatelessWidget {
  const SquareSwitchListTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final enabled = onChanged != null;
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        enabled: enabled,
        child: ListTile(
          contentPadding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(),
          enabled: enabled,
          title: title,
          subtitle: subtitle,
          onTap: enabled
              ? feedbackAction(context, () => onChanged!(!value))
              : null,
          trailing: ExcludeSemantics(
            child: AnimatedContainer(
              key: const ValueKey('square-switch-track'),
              duration: duration,
              curve: Curves.easeOutCubic,
              width: 48,
              height: 28,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: !enabled
                    ? context.colors.stone
                    : value
                    ? context.colors.clay
                    : context.colors.oatWarm,
                border: Border.all(
                  color: enabled && value
                      ? context.colors.clay
                      : context.colors.cloudMedium,
                ),
              ),
              child: AnimatedAlign(
                duration: duration,
                curve: Curves.easeOutCubic,
                alignment: value
                    ? AlignmentDirectional.centerEnd
                    : AlignmentDirectional.centerStart,
                child: SizedBox.square(
                  dimension: 18,
                  child: ColoredBox(
                    color: value && enabled
                        ? context.colors.onDark
                        : context.colors.cloudDark,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
