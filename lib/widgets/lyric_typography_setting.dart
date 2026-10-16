import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import 'accessible_controls.dart';

class LyricTypographySetting extends StatelessWidget {
  const LyricTypographySetting({super.key, required this.state});
  final AppState state;
  static const weights = {400: '常规', 500: '中等', 600: '半粗', 700: '粗体'};

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrText(
          '歌词字号 · ${state.lyricFontSize.round()}',
          style: context.type.bodySm,
        ),
        AccessibleSlider(
          semanticLabel: '歌词字号',
          value: state.lyricFontSize,
          min: 14,
          max: 40,
          divisions: 26,
          label: '${state.lyricFontSize.round()}',
          onChanged: (value) => unawaited(state.setLyricFontSize(value)),
        ),
        TrText('歌词粗细', style: context.type.bodySm),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in weights.entries)
              ChoiceChip(
                label: TrText(
                  entry.value,
                  style: context.type.caption.copyWith(
                    fontWeight: FontWeight.values[entry.key ~/ 100 - 1],
                  ),
                ),
                showCheckmark: false,
                selected: state.lyricFontWeight == entry.key,
                selectedColor: context.colors.clay.withValues(alpha: .16),
                backgroundColor: context.colors.ivoryLight,
                shape: const RoundedRectangleBorder(),
                onSelected: (_) =>
                    unawaited(state.setLyricFontWeight(entry.key)),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.colors.ivoryLight,
            border: Border.fromBorderSide(context.borders.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrText('歌词样式预览', style: context.type.captionMuted),
              const SizedBox(height: 12),
              AnimatedDefaultTextStyle(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                style: context.type.body.copyWith(
                  fontSize: state.lyricFontSize,
                  fontWeight:
                      FontWeight.values[state.lyricFontWeight ~/ 100 - 1],
                  height: 1.5,
                ),
                child: const TrText('让音乐陪你慢慢走'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    ),
  );
}
