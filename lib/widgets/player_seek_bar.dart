import 'package:flutter/material.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import 'haptic_seek_slider.dart';

class PlayerSeekBar extends StatelessWidget {
  const PlayerSeekBar({
    super.key,
    required this.state,
    this.trackHeight = 4,
    this.thumbRadius = 7,
  });

  final AppState state;
  final double trackHeight, thumbRadius;

  @override
  Widget build(BuildContext context) {
    // Leaf: the only part of Now Playing that consumes 100 ms ticks.
    return AnimatedBuilder(
      animation: state.all,
      builder: (BuildContext context, _) => SliderTheme(
        data: SliderThemeData(
          trackHeight: trackHeight,
          activeTrackColor: context.colors.slateDark,
          inactiveTrackColor: context.colors.stone,
          thumbColor: context.colors.clay,
          overlayColor: context.colors.clay.withValues(alpha: 0.16),
          thumbShape: RoundSliderThumbShape(enabledThumbRadius: thumbRadius),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
        ),
        child: HapticSeekSlider(state: state),
      ),
    );
  }
}
