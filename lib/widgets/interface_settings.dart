import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import 'accessible_controls.dart';
import 'square_switch_list_tile.dart';
import 'ui_scaling.dart';

/// The interface section of the settings sheet: the forced presentation, the
/// DPI scale slider and its automatic mode.
///
/// Listens to [AppState] itself because the settings page is rebuilt by the
/// shell, not by the state (the sibling settings widgets do the same).
class InterfaceSettings extends StatelessWidget {
  const InterfaceSettings({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (BuildContext context, _) {
      final double autoScale = UiMetrics.autoScaleOf(context);
      final double shownScale = state.autoDpiScale ? autoScale : state.dpiScale;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeading('界面'),
          const SizedBox(height: 12),
          DropdownButtonFormField<AppUiMode>(
            key: ValueKey(state.uiMode),
            initialValue: state.uiMode,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: context.tr('界面布局'),
              filled: true,
              fillColor: context.colors.ivoryLight,
              border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.zero,
                borderSide: context.borders.hairline,
              ),
            ),
            items: [
              for (final AppUiMode mode in AppUiMode.values)
                DropdownMenuItem<AppUiMode>(
                  value: mode,
                  child: Text(context.tr(mode.label)),
                ),
            ],
            onChanged: (AppUiMode? value) {
              if (value != null) unawaited(state.setUiMode(value));
            },
          ),
          const SizedBox(height: 6),
          TrText(
            state.uiMode.detail,
            style: context.type.captionMuted.copyWith(height: 1.5),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: TrText(
                  'DPI 缩放 · ${formatDpiScale(shownScale)}',
                  style: context.type.bodySm,
                ),
              ),
              TextButton(
                key: const ValueKey('dpi-scale-reset'),
                style: TextButton.styleFrom(
                  shape: const RoundedRectangleBorder(),
                ),
                onPressed: () => unawaited(state.resetDpiScale()),
                child: const TrText('恢复默认'),
              ),
            ],
          ),
          TrText(
            '80–175%；按比例放大整块界面，适合高分屏。',
            style: context.type.captionMuted,
          ),
          AccessibleSlider(
            key: const ValueKey('dpi-scale-slider'),
            semanticLabel: 'DPI 缩放',
            semanticFormatterCallback: (double value) =>
                '${(value * 100).round()}%',
            value: shownScale.clamp(kDpiScaleMin, kDpiScaleMax),
            min: kDpiScaleMin,
            max: kDpiScaleMax,
            divisions:
                ((kDpiScaleMax - kDpiScaleMin) / kDpiScaleStep).round(),
            detentFeedback: true,
            label: formatDpiScale(shownScale),
            onChanged: (double value) => unawaited(state.setDpiScale(value)),
            onChangeEnd: (_) => unawaited(state.feedback(boundary: true)),
          ),
          SquareSwitchListTile(
            key: const ValueKey('auto-dpi-switch'),
            title: const TrText('自动调节 DPI 缩放'),
            subtitle: const TrText('按窗口可用空间自动推算；拖动拉杆即改为手动'),
            value: state.autoDpiScale,
            onChanged: (bool value) => unawaited(state.setAutoDpiScale(value)),
          ),
        ],
      );
    },
  );
}
