import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'interaction_feedback.dart';

/// Keep a control's OverlayPortal and its anchor in the same semantics island.
/// Flutter 3.47 can otherwise serialize orphan nodes during route transitions
/// and tooltip changes (flutter/flutter#190357 and #182444).
/// This preserves the real control's semantics, focus and keyboard actions.
class SemanticsPortal extends StatelessWidget {
  const SemanticsPortal({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Overlay.wrap(
      alwaysSizeToContent: true,
      clipBehavior: Clip.none,
      child: child,
    ),
  );
}

class AccessibleSlider extends StatelessWidget {
  const AccessibleSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeStart,
    this.onChangeEnd,
    this.semanticLabel,
    this.semanticFormatterCallback,
    this.focusNode,
    this.autofocus = false,
  });
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final String? semanticLabel;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final SemanticFormatterCallback? semanticFormatterCallback;
  final FocusNode? focusNode;
  final bool autofocus;
  @override
  Widget build(BuildContext context) => SemanticsPortal(
    child: MergeSemantics(
      child: Semantics(
        label: semanticLabel == null ? null : context.tr(semanticLabel!),
        child: Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          label: label == null ? null : context.tr(label!),
          onChanged: onChanged,
          onChangeStart: onChangeStart,
          onChangeEnd: onChangeEnd,
          semanticFormatterCallback: semanticFormatterCallback == null
              ? null
              : (value) => context.tr(semanticFormatterCallback!(value)),
          focusNode: focusNode,
          autofocus: autofocus,
        ),
      ),
    ),
  );
}

/// Give each portal anchor a separate node while retaining the page overlay's
/// full bounds for tooltip placement and long labels.
class AccessibleTooltip extends StatelessWidget {
  const AccessibleTooltip({
    super.key,
    required this.message,
    required this.child,
  });
  final String message;
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: Tooltip(
      message: context.tr(message),
      enableFeedback: false,
      child: child,
    ),
  );
}

class AccessibleIconButton extends IconButton {
  const AccessibleIconButton({
    super.key,
    required super.icon,
    required super.onPressed,
    super.tooltip,
    super.isSelected,
    super.iconSize,
    super.padding,
    super.style,
    super.color,
    super.constraints,
    super.visualDensity,
    super.alignment,
    super.focusNode,
    super.autofocus,
    super.enableFeedback,
  });
  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: IconButton(
        icon: icon,
        onPressed: feedbackAction(context, onPressed),
        tooltip: tooltip == null ? null : context.tr(tooltip!),
        isSelected: isSelected,
        iconSize: iconSize,
        padding: padding,
        style: style,
        color: color,
        constraints: constraints,
        visualDensity: visualDensity,
        alignment: alignment,
        focusNode: focusNode,
        autofocus: autofocus,
        enableFeedback: false,
      ),
    );
  }
}
