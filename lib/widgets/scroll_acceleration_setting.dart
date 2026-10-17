import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import 'accessible_controls.dart';

class ScrollAccelerationSetting extends StatelessWidget {
  const ScrollAccelerationSetting({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: TrText(
                '滚动加速度 · ${(state.scrollAcceleration * 100).round()}%',
                style: context.type.bodySm,
              ),
            ),
            TextButton(
              key: const ValueKey('scroll-acceleration-reset'),
              style: TextButton.styleFrom(
                shape: const RoundedRectangleBorder(),
              ),
              onPressed: () => unawaited(
                state.setScrollAcceleration(ScrollMotion.defaultAcceleration),
              ),
              child: const TrText('恢复默认'),
            ),
          ],
        ),
        TrText('50–300%；数值越高，滚轮和连续甩动提速越明显。', style: context.type.captionMuted),
        AccessibleSlider(
          semanticLabel: '滚动加速度',
          semanticFormatterCallback: (value) => '${(value * 100).round()}%',
          value: state.scrollAcceleration,
          min: ScrollMotion.minAcceleration,
          max: ScrollMotion.maxAcceleration,
          divisions: 25,
          detentFeedback: true,
          label: '${(state.scrollAcceleration * 100).round()}%',
          onChanged: (value) =>
              unawaited(state.setScrollAcceleration((value * 10).round() / 10)),
        ),
      ],
    ),
  );
}
