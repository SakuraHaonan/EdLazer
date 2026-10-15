import 'dart:async';

import 'package:flutter/widgets.dart';

import '../state/app_state.dart';

/// Supplies feedback preferences without listening to raw pointer events.
class InteractionFeedback extends InheritedWidget {
  const InteractionFeedback({
    super.key,
    required this.state,
    required super.child,
  });
  final AppState state;
  static AppState? of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<InteractionFeedback>()?.state;
  @override
  bool updateShouldNotify(InteractionFeedback oldWidget) =>
      oldWidget.state != state;
}

VoidCallback? feedbackAction(BuildContext context, VoidCallback? action) {
  if (action == null) return null;
  return () {
    final state = InteractionFeedback.of(context);
    if (state != null) unawaited(state.feedback());
    action();
  };
}
