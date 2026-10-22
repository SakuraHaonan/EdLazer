import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'accessible_controls.dart';

class HapticSeekSlider extends StatelessWidget {
  const HapticSeekSlider({super.key, required this.state});
  final AppState state;
  @override
  Widget build(BuildContext context) => AccessibleSlider(
    semanticLabel: '播放进度',
    value: state.progress,
    detentFeedback: true,
    onChanged: state.current == null ? null : state.seek,
  );
}
