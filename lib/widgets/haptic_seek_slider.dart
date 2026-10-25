import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import '../tv/tv_mode.dart';
import 'accessible_controls.dart';

class HapticSeekSlider extends StatefulWidget {
  const HapticSeekSlider({super.key, required this.state});
  final AppState state;
  @override
  State<HapticSeekSlider> createState() => _HapticSeekSliderState();
}

class _HapticSeekSliderState extends State<HapticSeekSlider> {
  /// A D-pad step on the seek rail, in fractional track length.
  static const double _step = .02;

  bool _focused = false;

  void _nudge(double delta) {
    final AppState state = widget.state;
    if (state.current == null) return;
    state.seek((state.progress + delta).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final Widget slider = AccessibleSlider(
      semanticLabel: '播放进度',
      value: widget.state.progress,
      detentFeedback: true,
      onChanged: widget.state.current == null ? null : widget.state.seek,
    );
    if (!TvScope.isActive(context)) return slider;
    // Material sliders spend the up/down keys on their value. On a television
    // those keys must leave the rail instead: a remote's d-pad should move to
    // the row above or below, not scrub the song. Replacing the slider's focus
    // stop keeps left/right nudging and leaves up/down to the default
    // directional traversal.
    return FocusableActionDetector(
      enabled: widget.state.current != null,
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekStepIntent(-_step),
        SingleActivator(LogicalKeyboardKey.arrowRight): _SeekStepIntent(_step),
      },
      actions: <Type, Action<Intent>>{
        _SeekStepIntent: CallbackAction<_SeekStepIntent>(
          onInvoke: (_SeekStepIntent intent) {
            _nudge(intent.delta);
            return null;
          },
        ),
      },
      onFocusChange: (bool value) => setState(() => _focused = value),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ExcludeFocus(child: slider),
          if (_focused)
            Positioned.fill(
              child: IgnorePointer(
                child: TvFocusOutline(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SeekStepIntent extends Intent {
  const _SeekStepIntent(this.delta);
  final double delta;
}
