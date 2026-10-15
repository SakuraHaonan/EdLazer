import '../l10n/app_localizations.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../theme/design_tokens.dart';
import 'accessible_controls.dart';

class ScrollInertiaSetting extends StatefulWidget {
  const ScrollInertiaSetting({super.key, required this.state});
  final AppState state;

  @override
  State<ScrollInertiaSetting> createState() => _ScrollInertiaSettingState();
}

class _ScrollInertiaSettingState extends State<ScrollInertiaSetting> {
  late final TextEditingController _input = TextEditingController(
    text: _percent,
  );
  final FocusNode _focus = FocusNode();
  String get _percent =>
      (widget.state.scrollRetention * 100).round().toString();

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_changed);
    _focus.addListener(_commitOnBlur);
  }

  @override
  void didUpdateWidget(covariant ScrollInertiaSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_changed);
      widget.state.addListener(_changed);
      _input.text = _percent;
    }
  }

  void _changed() {
    if (!_focus.hasFocus && _input.text != _percent) _input.text = _percent;
    setState(() {});
  }

  void _apply(int percent, {bool updateInput = true}) {
    final value = percent.clamp(
      (ScrollMotion.minRetention * 100).round(),
      (ScrollMotion.maxRetention * 100).round(),
    );
    if (updateInput) _input.text = '$value';
    if ((widget.state.scrollRetention - value / 100).abs() > 1e-9) {
      unawaited(widget.state.setScrollRetention(value / 100));
    }
  }

  void _commit() => _apply(int.tryParse(_input.text) ?? int.parse(_percent));
  void _commitOnBlur() {
    if (!_focus.hasFocus) _commit();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(child: TrText('滚动惯性', style: AppText.bodySm)),
          Container(
            width: 80,
            height: 44,
            decoration: BoxDecoration(
              color: AppColors.ivoryLight,
              border: Border.all(color: AppColors.stone),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Semantics(
              label: context.tr('滚动惯性百分比'),
              child: TextField(
                key: const ValueKey('scroll-inertia-input'),
                controller: _input,
                focusNode: _focus,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                textAlign: TextAlign.right,
                style: AppText.bodySm,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  suffixText: '%',
                  contentPadding: EdgeInsets.symmetric(vertical: 10),
                ),
                onChanged: (text) {
                  final value = int.tryParse(text);
                  if (value != null &&
                      value >= ScrollMotion.minRetention * 100 &&
                      value <= ScrollMotion.maxRetention * 100) {
                    _apply(value, updateInput: false);
                  }
                },
                onSubmitted: (_) {
                  _commit();
                  _focus.unfocus();
                },
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('scroll-inertia-reset'),
            onPressed: () =>
                _apply((ScrollMotion.defaultRetention * 100).round()),
            child: const TrText('恢复默认'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      const TrText('85–98%；数值越高，松手后滑行越久、越远。', style: AppText.captionMuted),
      AccessibleSlider(
        semanticLabel: '滚动惯性',
        semanticFormatterCallback: (value) => '${(value * 100).round()}%',
        value: widget.state.scrollRetention,
        min: ScrollMotion.minRetention,
        max: ScrollMotion.maxRetention,
        divisions: 13,
        label: '$_percent%',
        onChanged: (value) => _apply((value * 100).round()),
      ),
    ],
  );

  @override
  void dispose() {
    widget.state.removeListener(_changed);
    _focus.removeListener(_commitOnBlur);
    _focus.dispose();
    _input.dispose();
    super.dispose();
  }
}
