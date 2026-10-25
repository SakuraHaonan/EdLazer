import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native bridge for Android TV recognition.
///
/// The manifest marks the app `LEANBACK_LAUNCHER`-capable, but Flutter still
/// needs to know whether the device it runs on is actually a television: a TV
/// has no touch screen and is driven by a D-pad remote, so every tappable
/// surface also has to be reachable with directional focus.
const MethodChannel _tvChannel = MethodChannel('dev.naominet.lazer/tv');

/// Whether the Android device under this app is a television.
///
/// Only Android can answer; every other platform keeps its existing input
/// model. A missing plugin (tests, hot-restart before the activity is wired)
/// is not an error — it simply means "not a TV".
Future<bool> detectTelevision() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    final bool? result = await _tvChannel
        .invokeMethod<bool>('isTelevision')
        .timeout(const Duration(milliseconds: 800));
    return result ?? false;
  } catch (_) {
    return false;
  }
}

/// Publishes whether the television interaction model is active.
///
/// This is separate from the density profile: a user can force the television
/// surface on a touch device for testing, and a TV can be told to use the
/// standard density without losing remote navigation.
class TvScope extends InheritedWidget {
  const TvScope({super.key, required this.active, required super.child});

  /// Whether tappable surfaces must also be focusable with a remote.
  final bool active;

  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvScope>()?.active ?? false;

  @override
  bool updateShouldNotify(TvScope oldWidget) => oldWidget.active != active;
}

/// Extra breathing room a television needs so overscan does not clip chrome.
///
/// Android TV reports no safe-area padding of its own, yet many panels crop a
/// few percent off every edge. The shell and the immersive player both inset
/// their content with this instead of relying on [SafeArea] alone.
EdgeInsets tvSafeInsets(BuildContext context) => TvScope.isActive(context)
    ? const EdgeInsets.fromLTRB(24, 16, 24, 16)
    : EdgeInsets.zero;

/// Registry of player panels drawn through [OverlayPortal].
///
/// Overlay entries are siblings of the route, so a remote Back press never
/// reaches them: the system pop would leave the app (or navigate the shell)
/// while the queue card stayed on screen. Panels register a closer here, and
/// the shell consumes Back with [closeTop] before its own navigation.
class TvOverlayStack extends ChangeNotifier {
  TvOverlayStack._();

  static final TvOverlayStack instance = TvOverlayStack._();

  final List<VoidCallback> _closers = <VoidCallback>[];

  bool get hasOpen => _closers.isNotEmpty;

  void push(VoidCallback close) {
    _closers.add(close);
    notifyListeners();
  }

  void remove(VoidCallback close) {
    if (_closers.remove(close)) notifyListeners();
  }

  /// Closes the most recently opened panel; false when nothing is open.
  bool closeTop() {
    if (_closers.isEmpty) return false;
    final VoidCallback close = _closers.removeLast();
    notifyListeners();
    close();
    return true;
  }
}

/// A tap target that also participates in D-pad focus traversal.
///
/// The shell draws every card, row and transport glyph with a
/// [GestureDetector], which a remote can never reach. On a television this
/// widget adds the missing half: a focus node in the directional traversal
/// order, ActivateIntent handling (the Select/Enter key), and a high-contrast
/// ring at ten-foot distance. Off a TV it returns [child] untouched, so the
/// pointer, hover and semantics behaviour of the existing widgets is unchanged.
class TvTapTarget extends StatefulWidget {
  const TvTapTarget({
    super.key,
    required this.child,
    this.onTap,
    this.enabled = true,
    this.autofocus = false,
    this.focusNode,
    this.onFocusChange,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.focusScale = 1.02,
  });

  final Widget child;
  final VoidCallback? onTap;
  final bool enabled;
  final bool autofocus;
  final FocusNode? focusNode;

  /// Lets a card treat remote focus like hover (raise its play badge, lift the
  /// artwork) without duplicating a second focus listener.
  final ValueChanged<bool>? onFocusChange;

  /// Shape of the focus ring; match the card's own corner radius.
  final BorderRadius borderRadius;

  /// A slight lift makes the focused card read as selected from across a room.
  final double focusScale;

  @override
  State<TvTapTarget> createState() => _TvTapTargetState();
}

class _TvTapTargetState extends State<TvTapTarget> {
  bool _focused = false;

  void _setFocused(bool value) {
    if (_focused == value) return;
    setState(() => _focused = value);
    widget.onFocusChange?.call(value);
  }

  void _activate() {
    if (!widget.enabled) return;
    widget.onTap?.call();
  }

  @override
  void didUpdateWidget(covariant TvTapTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && _focused) _setFocused(false);
  }

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.enabled && widget.onTap != null;
    if (!TvScope.isActive(context) || !interactive) return widget.child;
    return FocusableActionDetector(
      enabled: true,
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onFocusChange: _setFocused,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            _activate();
            return null;
          },
        ),
      },
      child: AnimatedScale(
        scale: _focused ? widget.focusScale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            widget.child,
            if (_focused)
              Positioned.fill(
                child: IgnorePointer(
                  child: TvFocusOutline(borderRadius: widget.borderRadius),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The white ring + black halo used for remote focus everywhere.
///
/// White alone disappears over light artwork and black alone disappears over
/// the dark player, so the two are drawn together: the shadow outlines the
/// ring on white, and the ring stays crisp on black.
class TvFocusOutline extends StatelessWidget {
  const TvFocusOutline({
    super.key,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.width = 2.5,
  });

  final BorderRadius borderRadius;
  final double width;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: borderRadius,
      border: Border.all(color: Colors.white, width: width),
      boxShadow: const <BoxShadow>[
        BoxShadow(color: Color(0xB3000000), blurRadius: 2, spreadRadius: 2),
      ],
    ),
  );
}

/// Moves remote focus into a page when it appears or returns to the front.
///
/// A remote starts with no pointer and therefore no focus: without an anchor
/// the first D-pad press does nothing. Each page owns one of these regions;
/// when its [focusToken] changes (a new section, a closed player) the first
/// actionable descendant receives focus. The region is a plain [Focus] node,
/// not a [FocusScope], so traversal can still leave the content for the rail
/// and the transport bar.
class TvFocusRegion extends StatefulWidget {
  const TvFocusRegion({super.key, required this.child, this.focusToken});

  final Widget child;

  /// Changing this value re-acquires focus for the region's first control.
  final Object? focusToken;

  @override
  State<TvFocusRegion> createState() => _TvFocusRegionState();
}

class _TvFocusRegionState extends State<TvFocusRegion> {
  final FocusNode _region = FocusNode(
    debugLabel: 'tv-focus-region',
    canRequestFocus: false,
    skipTraversal: true,
  );
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (TvScope.isActive(context)) _schedule();
  }

  @override
  void didUpdateWidget(covariant TvFocusRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusToken != widget.focusToken) _schedule();
  }

  @override
  void dispose() {
    _region.dispose();
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !TvScope.isActive(context)) return;
      final FocusNode? primary = FocusManager.instance.primaryFocus;
      // Focus already lives in this page (for example after a rebuild): don't
      // yank it back to the top.
      if (primary != null && _isInside(primary)) return;
      final FocusNode? first = _region.traversalDescendants
          .where((FocusNode node) => node.context != null)
          .firstOrNull;
      first?.requestFocus();
    });
  }

  bool _isInside(FocusNode node) {
    for (FocusNode? current = node; current != null; current = current.parent) {
      if (current == _region) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (!TvScope.isActive(context)) return widget.child;
    return Focus(
      focusNode: _region,
      canRequestFocus: false,
      skipTraversal: true,
      child: widget.child,
    );
  }
}
