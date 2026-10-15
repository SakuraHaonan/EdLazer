import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';

/// One feedback pulse per touch across pages, sheets, dialogs, and controls.
/// A Listener leaves the gesture arena and back gestures untouched.
class InteractionFeedback extends StatelessWidget {
  const InteractionFeedback({
    super.key,
    required this.state,
    required this.child,
  });
  final AppState state;
  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      if (state.hapticsEnabled && event.kind == PointerDeviceKind.touch) {
        HapticFeedback.selectionClick();
      }
    },
    child: child,
  );
}
