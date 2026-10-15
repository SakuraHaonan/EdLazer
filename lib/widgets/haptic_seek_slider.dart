import 'dart:async';

import 'package:flutter/material.dart';

import '../interaction/app_haptics.dart';
import '../state/app_state.dart';
import 'accessible_controls.dart';

class HapticSeekSlider extends StatefulWidget {
  const HapticSeekSlider({super.key, required this.state});
  final AppState state;
  @override
  State<HapticSeekSlider> createState() => _HapticSeekSliderState();
}

class _HapticSeekSliderState extends State<HapticSeekSlider> {
  final SeekDetents _detents = SeekDetents();
  @override
  Widget build(BuildContext context) => AccessibleSlider(
    semanticLabel: '播放进度',
    value: widget.state.progress,
    onChangeStart: widget.state.current == null
        ? null
        : (value) {
            _detents.begin(value);
            unawaited(widget.state.feedback(detent: true));
          },
    onChanged: widget.state.current == null
        ? null
        : (value) {
            if (_detents.update(value)) {
              unawaited(
                widget.state.feedback(
                  detent: true,
                  boundary: value <= 0 || value >= 1,
                ),
              );
            }
            widget.state.seek(value);
          },
    onChangeEnd: (_) => _detents.end(),
  );
}
