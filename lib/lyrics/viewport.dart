import 'package:lazer_nextgen/theme/app_palette.dart';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../animation/lyric_spring.dart';
import '../data/lyrics.dart';
import '../data/lyric_selection.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../theme/tokens.dart';
import 'cached_blur.dart';
import 'lyric_quality.dart';
import 'lyrics_import.dart';
import '../widgets/lyric_selection_toolbar.dart';
import '../widgets/lyric_image_dialog.dart';
import '../widgets/lyric_edge_fade.dart';
import '../widgets/timed_lyric_text.dart';
import '../widgets/lyric_text_hit_region.dart';

/// children stay cached while the ticker only updates their transforms.
class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.state,
    this.backdropKey,
    this.onSelectionChanged,
  });
  final AppState state;

  /// The live player backdrop boundary, captured when exporting an image.
  final GlobalKey? backdropKey;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<LyricViewport> createState() => _LyricViewportState();
}

/// Crisp, non-bouncing line motion: critically damped (ζ≈1), settles in
/// ~300 ms with no overshoot. Replaces the stagger + under-damped policy.
const LyricSpringParams _kLineSpring = LyricSpringParams(
  mass: 1,
  stiffness: 260,
  damping: 33,
);

/// A seek travels further; a slightly softer (still critically damped)
/// spring keeps it from snapping.
const LyricSpringParams _kSeekSpring = LyricSpringParams(
  mass: 1,
  stiffness: 170,
  damping: 27,
);

/// Active-line emphasis (scale 97→100 and colour), eased in ~250 ms.
const LyricSpringParams _kEmphasisSpring = LyricSpringParams(
  mass: 1,
  stiffness: 300,
  damping: 35,
);

class _LyricViewportState extends State<LyricViewport>
    with TickerProviderStateMixin {
  /// Android (Impeller, no raster cache) renders the distance blur through
  /// [CachedBlur]: each row is blurred once per sigma bucket and then drawn
  /// as a bitmap, instead of re-running ten blur passes on every frame.
  // Read per frame rather than cached so tests (and platform overrides) can
  // flip it.
  static bool get _android => defaultTargetPlatform == TargetPlatform.android;

  /// The effect tier: the user's 歌词特效质量 setting, or for 自动 the frame
  /// timing governor's current pick.
  LyricFxTier get _tier => lyricFxTierFor(widget.state.lyricFxQuality);

  /// Minimal tier: the beta.7 cheap path (no blur, glow or pulse, one
  /// vertical edge mask).
  bool get _lite => _tier == LyricFxTier.minimal;
  bool get _cachedBlur => _android || _tier == LyricFxTier.reduced;
  late LyricFxTier _lastTier = _tier;
  Ticker? _ticker;
  late final AnimationController _blur = AnimationController(
    vsync: this,
    duration: AppMotion.standard,
    value: widget.state.lyricBlurEnabled ? 1 : 0,
  );
  final ValueNotifier<int> _frames = ValueNotifier(0);
  final Stopwatch _wall = Stopwatch()..start();
  List<LyricLine> _lines = [];
  bool _hasWordTimings = false;
  List<LyricSpring> _ys = [];
  List<LyricSpring> _scales = [];
  List<double> _heights = [];
  List<double> _prefix = [];
  double _rowUnit = 0;
  final Map<int, Widget> _rowCache = <int, Widget>{};
  List<ValueNotifier<int>> _rowFrames = const <ValueNotifier<int>>[];
  Size _size = Size.zero;

  /// The width rows were last measured at. A width that is still changing
  /// (the landscape controls sliding in or out) is not re-measured on every
  /// frame; rows keep this width until the pane has held still for a frame.
  double _layoutWidth = 0;
  bool _widthCheckScheduled = false;
  bool _applyWidth = false;
  double _probeWidth = -1;
  double get _gutter =>
      math.min(LyricEdgeFade.horizontalExtent, _layoutWidth * 0.1);
  double get _textWidth => math.max(1.0, _layoutWidth - _gutter * 2);
  TextScaler? _textScaler;
  double? _fontSize;
  int? _fontWeight;
  int _active = -1;
  bool _playing = false;
  bool _manual = false;
  bool _dragging = false;
  int? _middlePointer;
  double _offset = 0;
  double _velocity = 0;
  Duration _lastFrame = Duration.zero;
  Duration? _lastLanePosition;
  Duration? _lastMedia;
  int _lastWall = 0;
  Timer? _resume;
  double _dragCarry = 0;
  LyricSelection _selection = const LyricSelection();
  bool _copied = false;
  Timer? _copiedTimer;
  int _selectionRevision = 0;
  String? _trackId;
  int _dragArmedAt = -1000;
  bool _extendingSelection = false;
  final GlobalKey _viewportKey = GlobalKey();
  late double _blurTarget = widget.state.lyricBlurEnabled ? 1 : 0;

  @override
  void initState() {
    super.initState();
    _trackId = widget.state.current?.id;
    widget.state.all.addListener(_onLane);
    LyricFxGovernor.instance.addListener(_onTier);
  }

  /// A tier change (setting or governor) rebuilds the cached rows so their
  /// glow / pulse flags and blur path follow.
  void _onTier() {
    if (!mounted) return;
    final LyricFxTier tier = _tier;
    if (tier == _lastTier) return;
    setState(() {
      _lastTier = tier;
      _rowCache.clear();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ticker ??= createTicker(_tick);
  }

  @override
  void didUpdateWidget(covariant LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.all.removeListener(_onLane);
      widget.state.all.addListener(_onLane);
    }
    _updateBlur();
  }

  void _followLine() {
    if (!mounted || !identical(_lines, widget.state.lyrics) || _lines.isEmpty) {
      return;
    }
    final active = _activeAt(widget.state.precisePosition);
    if (active == _active) return;
    setState(() {
      _invalidateRows(_active, active);
      _active = active;
      _targets();
      _scaleTargets();
    });
  }

  int _activeAt(Duration position) {
    final lines = widget.state.lyrics;
    var low = 0;
    var high = lines.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (lines[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low - 1;
  }

  bool _isSeek() {
    final media = widget.state.position;
    final now = _wall.elapsedMilliseconds;
    final old = _lastMedia;
    final wallDelta = (now - _lastWall).clamp(0, 800);
    _lastMedia = media;
    _lastWall = now;
    if (old == null) return false;
    final delta = (media - old).inMilliseconds;
    return delta < 0 ||
        delta - (widget.state.playing ? wallDelta : 0) >
            (widget.state.playing ? math.max(150, wallDelta * 0.5) : 150);
  }

  void _onLane() {
    if (!mounted) return;
    final active = _activeAt(widget.state.precisePosition);
    final seeking = _isSeek();
    final changed = !identical(_lines, widget.state.lyrics);
    final typographyChanged =
        _fontSize != widget.state.lyricFontSize ||
        _fontWeight != widget.state.lyricFontWeight;
    if (_trackId != widget.state.current?.id) {
      _trackId = widget.state.current?.id;
      if (_selection.active) {
        _changeSelection(const LyricSelection(), resume: false);
      }
    }
    if (changed) {
      _resume?.cancel();
      if (_selection.active) {
        final available = {
          for (final line in widget.state.lyrics) ?lyricSelectionKey(line),
        };
        final retained = _selection.keys.intersection(available);
        _changeSelection(
          retained.isEmpty
              ? const LyricSelection()
              : LyricSelection(
                  anchor: retained.contains(_selection.anchor)
                      ? _selection.anchor
                      : retained.first,
                  keys: retained,
                ),
          resume: false,
        );
      }
      _manual = _selection.active;
      _velocity = 0;
    }
    if (changed || typographyChanged || active != _active) {
      setState(() {
        if (changed || typographyChanged) {
          _rowCache.clear();
        } else {
          _invalidateRows(_active, active);
        }
        _active = active;
        if (!changed && !_manual) _targets(seeking: seeking);
        _scaleTargets();
      });
    }
    if (_playing != widget.state.playing) {
      _playing = widget.state.playing;
      // Resuming mid-song must restart word animation even though no spring
      // is retargeted; the old code got this (and a full stagger restart) by
      // retargeting every row on the play-state change.
      if (_playing && _hasWordTimings) _start();
    }
    // Only a paused seek changes the word mask without a running ticker. A
    // playback tick (10 Hz) must not repaint every mounted row.
    final Duration precise = widget.state.precisePosition;
    if (_hasWordTimings &&
        !widget.state.playing &&
        precise != _lastLanePosition) {
      if (_active >= 0 && _active < _rowFrames.length) {
        _rowFrames[_active].value++;
      }
    }
    _lastLanePosition = precise;
    _updateBlur();
    _onTier();
  }

  /// A line change only alters the outgoing and incoming rows; every other
  /// cached row (and its laid-out paragraphs) is kept. Clearing the whole
  /// cache here rebuilt and re-laid-out every visible line on each change.
  void _invalidateRows(int previous, int next) {
    _rowCache.remove(previous);
    _rowCache.remove(next);
  }

  void _updateBlur() {
    final target = widget.state.lyricBlurEnabled && !_manual ? 1.0 : 0.0;
    if (_blurTarget != target) {
      _blurTarget = target;
      _blur.animateTo(target, curve: AppMotion.standardCurve);
    }
  }

  /// Blur tracks how far a row sits from the focus band instead of its index
  /// gap, so it ramps in and out as rows travel rather than snapping to zero
  /// the instant a line becomes active.
  double _sigma(int i) {
    if (_lite || _rowUnit <= 0 || _blur.value <= 0) return 0;
    final centre = _ys[i].value + _heights[i] * 0.5;
    final distance = (centre - _size.height * 0.35).abs() / _rowUnit;
    return math.min(5.0, distance * 1.55) * _blur.value;
  }

  /// Dissolves rows into the viewport edges so the clip never slices a blurred
  /// line clean in half.
  Widget _edgeFade(Widget child) => LyricEdgeFade(
    verticalExtent: math.min(
      _size.height * 0.22,
      math.max(28.0, _rowUnit * 1.15),
    ),
    // The desktop canvas is wide enough for its 18 px gutter to contain the
    // blur halo. Compact panes fade the sides too; that is folded into the
    // same single ShaderMask pass rather than a second nested one.
    horizontal: !_lite && _size.width < 520,
    child: child,
  );

  void _start() {
    final Ticker? ticker = _ticker;
    if (ticker != null && !ticker.isActive) {
      _lastFrame = Duration.zero;
      ticker.start();
      LyricFxGovernor.instance.setAnimating(this, true);
    }
  }

  void _tick(Duration elapsed) {
    // Every vsync updates the lyric springs. The old 16 ms gate turned a
    // 100 Hz panel into 50 lyric updates per second (and 80 Hz into 40), so
    // the animation could never reach the requested 80 fps even when the UI
    // thread had headroom.
    final dt = ((elapsed - _lastFrame).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastFrame = elapsed;
    if (widget.state.playing) _followLine();
    if (_manual && !_dragging && _velocity.abs() > 5 && dt > 0) {
      final previous = _offset;
      _setOffset(_offset + _velocity * dt);
      _velocity *= math.pow(widget.state.scrollRetention, dt * 60);
      if (_offset == previous) _velocity = 0;
    }
    var moving =
        _manual && _velocity.abs() > 5 ||
        widget.state.playing && _hasWordTimings;
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].update(dt);
      _scales[i].update(dt);
      moving = moving || !_ys[i].arrived || !_scales[i].arrived;
    }
    // Only the active word row needs a paint every frame; a row whose scale
    // is still easing needs one for its colour fade. Everything else stays
    // behind its RepaintBoundary even though the outer stack keeps moving.
    final bool wordFrame = widget.state.playing && _hasWordTimings;
    for (var i = 0; i < _rowFrames.length && i < _scales.length; i++) {
      if (wordFrame && i == _active || !_scales[i].arrived) {
        _rowFrames[i].value++;
      }
    }
    _frames.value++;
    if (!moving) {
      _ticker?.stop();
      LyricFxGovernor.instance.setAnimating(this, false);
    }
  }

  void _scaleTargets() {
    for (var i = 0; i < _scales.length; i++) {
      _scales[i].setTarget(i == _active ? 100 : 97);
    }
    if (_scales.isNotEmpty) _start();
  }

  void _targets({bool seeking = false, bool stagger = true}) {
    if (_ys.isEmpty || _size.height <= 0 || _manual) return;
    final focus = _active.clamp(0, _lines.length - 1);
    final anchor = _prefix[focus] - _size.height * 0.35 + _heights[focus] / 2;
    final positions = [
      for (var i = 0; i < _lines.length; i++) _prefix[i] - anchor,
    ];
    // The first and last line have no neighbouring interval, and the upstream
    // policy gives them a soft under-damped spring. On a long sheet every row
    // then kept oscillating at the edges and the 60 fps ticker never settled.
    // Use the same damped baseline as the middle transitions instead; seeking
    // keeps its intentionally soft animation.
    // Crisp motion: every row eases to its slot together on a critically
    // damped spring. No per-row stagger, no under-damped edge/seek springs —
    // those were the overshoot and "wobble" in the old sheet.
    final params = seeking ? _kSeekSpring : _kLineSpring;
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].setParameters(params);
      // Rows that are nowhere near the viewport do not need a spring or a
      // stagger delay: put them at their new position immediately. This is
      // what keeps the opening and closing seconds of a long lyric sheet from
      // animating hundreds of invisible rows.
      final double target = positions[i];
      final bool nearViewport =
          target + _heights[i] >= -_size.height * 0.5 &&
          target <= _size.height * 1.5;
      if (nearViewport) {
        _ys[i].setTarget(target);
      } else {
        _ys[i].setPosition(target);
      }
    }
    _scaleTargets();
    _start();
  }

  TextStyle get _originalStyle => context.type.bodySm.copyWith(
    fontSize: widget.state.lyricFontSize,
    height: 1.5,
    fontWeight: FontWeight.values[widget.state.lyricFontWeight ~/ 100 - 1],
  );
  TextStyle get _translationStyle => context.type.bodySm.copyWith(
    fontSize: (widget.state.lyricFontSize * 16 / 22).clamp(12, 30),
    height: 1.45,
    color: Colors.white,
  );
  double _measureText(
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  void _layout(Size size, TextScaler scaler) {
    final replaced = !identical(_lines, widget.state.lyrics);
    final typographyChanged =
        _fontSize != widget.state.lyricFontSize ||
        _fontWeight != widget.state.lyricFontWeight;
    final bool applyWidth = _applyWidth;
    _applyWidth = false;
    if (!replaced &&
        !typographyChanged &&
        size == _size &&
        scaler == _textScaler &&
        !(applyWidth && size.width != _layoutWidth)) {
      return;
    }
    final bool widthChanged = size.width != _layoutWidth;
    // Only a pure width change is deferred, and only once rows exist; new
    // lyrics, typography or text scale always measure right away.
    final bool deferWidth =
        widthChanged &&
        !applyWidth &&
        !replaced &&
        !typographyChanged &&
        scaler == _textScaler &&
        _layoutWidth > 0 &&
        _heights.isNotEmpty;
    final needsMeasure =
        replaced ||
        typographyChanged ||
        (widthChanged && !deferWidth) ||
        scaler != _textScaler;
    _size = size;
    if (deferWidth) _scheduleWidthCheck();
    if (needsMeasure) _layoutWidth = size.width;
    _textScaler = scaler;
    _fontSize = widget.state.lyricFontSize;
    _fontWeight = widget.state.lyricFontWeight;
    _lines = widget.state.lyrics;
    _hasWordTimings = _lines.any((line) => line.words.isNotEmpty);
    _active = _activeAt(widget.state.precisePosition);
    if (needsMeasure) {
      _heights = [
        for (final line in _lines)
          _measureText(line.text, _originalStyle, _textWidth, scaler) +
              (line.translation == null
                  ? 0
                  : 5 +
                        _measureText(
                          line.translation!,
                          _translationStyle,
                          _textWidth,
                          scaler,
                        )) +
              20,
      ];
      var sum = 0.0;
      _prefix = [
        for (final height in _heights)
          (() {
            final y = sum;
            sum += height;
            return y;
          })(),
      ];
      _rowUnit = _heights.isEmpty ? 0 : sum / _heights.length;
      _rowCache.clear();
    }
    if (replaced) {
      _ys = [
        // The first reveal used to start two screens below the viewport; the
        // whole sheet then travelled that distance on the soft edge spring.
        // A shorter runway keeps the opening frame cheap and still reads as a
        // reveal.
        for (var i = 0; i < _lines.length; i++) LyricSpring(size.height * .7),
      ];
      _scales = [
        for (var i = 0; i < _lines.length; i++)
          LyricSpring(i == _active ? 100 : 97, params: _kEmphasisSpring),
      ];
      for (final notifier in _rowFrames) {
        notifier.dispose();
      }
      _rowFrames = [
        for (var i = 0; i < _lines.length; i++) ValueNotifier<int>(0),
      ];
      _manual = _selection.active;
    }
    if (_manual) {
      _setOffset(_offset);
    } else {
      _targets(stagger: false);
    }
  }

  /// Re-measures rows once the pane width has stopped changing: a post-frame
  /// check that waits for one frame at the same width. Post-frame callbacks
  /// (not timers) keep widget tests free of pending timers.
  void _scheduleWidthCheck() {
    if (_widthCheckScheduled) return;
    _widthCheckScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _widthCheckScheduled = false;
      if (!mounted || _size.width == _layoutWidth) return;
      if (_size.width == _probeWidth) {
        setState(() => _applyWidth = true);
      } else {
        _probeWidth = _size.width;
        _scheduleWidthCheck();
        SchedulerBinding.instance.ensureVisualUpdate();
      }
    });
  }

  void _beginManual({bool stopMomentum = true}) {
    _resume?.cancel();
    if (stopMomentum) _velocity = 0;
    if (_manual || _ys.isEmpty) return;
    final focus = _active.clamp(0, _lines.length - 1);
    _offset = _prefix[focus] - _ys[focus].value;
    _manual = true;
    _updateBlur();
    _frames.value++;
  }

  void _setOffset(double value) {
    if (_ys.isEmpty) return;
    final min = -_size.height * 0.35 + _heights.first / 2;
    final max = math.max(
      min,
      _prefix.last - _size.height * 0.35 + _heights.last / 2,
    );
    _offset = value.clamp(min, max);
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].setPosition(_prefix[i] - _offset);
    }
    _frames.value++;
  }

  void _scheduleResume() {
    _resume?.cancel();
    if (_selection.active) return;
    _resume = Timer(
      Duration(milliseconds: (widget.state.lyricResumeSeconds * 1000).round()),
      () {
        if (!mounted || _dragging) return;
        _manual = _selection.active;
        _velocity = 0;
        _targets(seeking: true);
        _updateBlur();
      },
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        _ys.isEmpty ||
        event.scrollDelta.dy == 0) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      _beginManual(stopMomentum: false);
      _velocity = ScrollMotion.addWheelImpulse(
        _velocity,
        event.scrollDelta.dy,
        acceleration: widget.state.scrollAcceleration,
      );
      _start();
      _scheduleResume();
    });
  }

  void _seek(int index) {
    final duration = widget.state.current?.duration.inMilliseconds ?? 0;
    if (duration <= 0) return;
    _resume?.cancel();
    _manual = false;
    _velocity = 0;
    widget.state.seek(_lines[index].time.inMilliseconds / duration);
    _targets(seeking: true);
    _updateBlur();
  }

  void _tapLine(int index) {
    unawaited(widget.state.feedback());
    _seek(index);
  }

  void _changeSelection(LyricSelection next, {bool resume = true}) {
    final changed = _selection.active != next.active;
    setState(() {
      _selection = next;
      _selectionRevision++;
      _copied = false;
      _rowCache.clear();
    });
    _copiedTimer?.cancel();
    if (changed) widget.onSelectionChanged?.call(next.active);
    if (!next.active && resume) _scheduleResume();
  }

  void _selectLyrics(int index) {
    if (lyricSelectionKey(_lines[index]) == null) return;
    unawaited(widget.state.feedback());
    _beginManual();
    // Freeze every row at its painted position, including unfinished springs.
    for (final spring in _ys) {
      spring.setPosition(spring.value);
    }
    _resume?.cancel();
    _dragArmedAt = _wall.elapsedMilliseconds;
    _changeSelection(
      _selection.active
          ? _selection.extend(_lines, index)
          : _selection.begin(_lines, index),
    );
  }

  void _extendSelection(Offset globalPosition) {
    final box = _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _lines.isEmpty) return;
    final y = box.globalToLocal(globalPosition).dy;
    var nearest = -1;
    var distance = double.infinity;
    for (var i = 0; i < _lines.length; i++) {
      if (lyricSelectionKey(_lines[i]) == null) continue;
      final delta = (_ys[i].value + _heights[i] / 2 - y).abs();
      if (delta < distance) {
        distance = delta;
        nearest = i;
      }
    }
    if (nearest >= 0) _changeSelection(_selection.extend(_lines, nearest));
  }

  Future<void> _copyLyrics() async {
    final revision = _selectionRevision;
    await Clipboard.setData(ClipboardData(text: _selection.text(_lines)));
    if (!mounted || revision != _selectionRevision) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _createImage() async {
    final track = widget.state.current;
    if (track == null) return;
    final selected = [
      for (final line in _lines)
        if (_selection.keys.contains(lyricSelectionKey(line))) line,
    ];
    if (selected.isEmpty) return;
    final backdrop = await captureLyricBackdrop(widget.backdropKey);
    if (!mounted) {
      backdrop?.dispose();
      return;
    }
    await showLyricImageDialog(
      context,
      track: track,
      lines: selected,
      background: backdrop,
    );
  }

  Widget _interactiveText(
    int index,
    String text,
    TextStyle style,
    Widget child,
  ) => LyricTextHitRegion(
    text: text,
    style: style,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selection.active
          ? _changeSelection(_selection.toggle(_lines, index))
          : _tapLine(index),
      onLongPress: () => _selectLyrics(index),
      onLongPressMoveUpdate: (event) => _extendSelection(event.globalPosition),
      onLongPressEnd: (_) => _dragArmedAt = _wall.elapsedMilliseconds,
      child: child,
    ),
  );

  /// Builds a row lazily and keeps it across frames; only viewport rows are
  /// ever constructed, so a 1,000-line sheet no longer allocates 1,000 row
  /// widgets every time the active line changes.
  Widget _cachedRow(int index) => _rowCache[index] ??= _row(index);

  Widget _row(int index) {
    final bool selectedKey = _selection.keys.contains(
      lyricSelectionKey(_lines[index]),
    );
    return Semantics(
      selected: _selection.active ? selectedKey : null,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: selectedKey ? 1 : 0),
        duration: AppMotion.emphasized,
        curve: AppMotion.standardCurve,
        // Opacity only while selecting; at 1.0 AnimatedOpacity adds no layer.
        builder: (context, selected, _) => AnimatedOpacity(
          opacity: _selection.active ? 0.54 + selected * 0.46 : 1,
          duration: AppMotion.quick,
          curve: AppMotion.fadeCurve,
          child: _rowBody(index, selected),
        ),
      ),
    );
  }

  /// Row colour is painted straight into the text (no ColorFiltered): the old
  /// srcIn colour filter was a saveLayer per visible row, re-composited on
  /// every frame while the sheet moved.
  Widget _rowBody(int index, double selected) {
    final focused = index == _active;
    final Listenable rowFrames = index < _rowFrames.length
        ? _rowFrames[index]
        : _frames;
    double emphasis() => ((_scales[index].value - 97) / 3).clamp(0.0, 1.0);
    double mainAlpha() {
      final double a = 0.48 + emphasis() * 0.52;
      return a + (1 - a) * selected;
    }

    final style = _originalStyle.copyWith(color: Colors.white);
    final LyricLine line = _lines[index];
    final Widget main = line.words.isNotEmpty
        ? TimedLyricText(
            line: line,
            style: style,
            active: focused,
            emphasis: emphasis,
            lift: () => selected,
            lite: _lite,
            glow: _tier == LyricFxTier.full,
            position: () => widget.state.precisePosition,
            repaint: rowFrames,
          )
        : AnimatedBuilder(
            animation: rowFrames,
            builder: (context, _) => Text(
              line.text.isEmpty ? ' ' : line.text,
              textAlign: TextAlign.left,
              textDirection: TextDirection.ltr,
              style: style.copyWith(
                color: Colors.white.withValues(alpha: mainAlpha()),
              ),
            ),
          );
    return SizedBox(
      width: _textWidth,
      height: _heights[index],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _interactiveText(index, line.text, style, main),
          if (line.translation != null) ...[
            const SizedBox(height: 5),
            _interactiveText(
              index,
              line.translation!,
              _translationStyle,
              AnimatedBuilder(
                animation: rowFrames,
                builder: (context, _) => Text(
                  line.translation!,
                  textAlign: TextAlign.left,
                  textDirection: TextDirection.ltr,
                  style: _translationStyle.copyWith(
                    color: Colors.white.withValues(alpha: mainAlpha() * 0.58),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One mounted lyric row. The index-only key keeps the element (and its
  /// painted layer) alive when the next song's lyrics arrive, instead of
  /// tearing the whole sheet down and measuring every line again.
  Widget _positionedRow(int index) {
    final double sigma = _sigma(index);
    return Positioned(
      key: ValueKey('lyric-line-$index'),
      top: 0,
      left: _gutter,
      width: _textWidth,
      height: _heights[index],
      child: Transform.translate(
        offset: Offset(0, _ys[index].value),
        child: Transform.scale(
          scale: _scales[index].value / 100,
          alignment: Alignment.centerLeft,
          child: _cachedBlur
              ? CachedBlur(
                  key: ValueKey('lyric-blur-$index'),
                  sigma: _cachedSigma(sigma),
                  devicePixelRatio: _devicePixelRatio,
                  coarse: _tier == LyricFxTier.reduced,
                  // CachedBlur is itself the row's repaint boundary.
                  child: _cachedRow(index),
                )
              : ImageFiltered(
                  key: ValueKey('lyric-blur-$index'),
                  enabled: sigma > 0.02,
                  imageFilter: _blurFilter(sigma),
                  // Every row gets its own layer: a per-word row otherwise
                  // repaints the whole lyric stack on each of its frames.
                  child: RepaintBoundary(child: _cachedRow(index)),
                ),
        ),
      ),
    );
  }

  double _devicePixelRatio = 1;

  /// Cached rows re-rasterize only when their sigma crosses a bucket: half a
  /// pixel on the full tier, a whole pixel on the reduced one.
  double _cachedSigma(double sigma) {
    final double step = _tier == LyricFxTier.reduced ? 1 : .5;
    return (sigma / step).round() * step;
  }

  /// Blur sigmas are quantized so neighbouring frames reuse one filter object
  /// instead of allocating and reconfiguring an `ImageFilter` per row.
  static final Map<int, ui.ImageFilter> _blurFilters = <int, ui.ImageFilter>{};

  static ui.ImageFilter _blurFilter(double sigma) {
    final int step = (sigma * 8).round();
    return _blurFilters[step] ??= ui.ImageFilter.blur(
      sigmaX: step / 8,
      sigmaY: step / 8,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.state.lyricsLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.state.lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrText(
              widget.state.lyricsError ??
                  (widget.state.lyricsPureMusic ? '纯音乐' : '这首歌暂未提供歌词'),
              style: context.type.captionMuted,
            ),
            if (!widget.state.lyricsPureMusic)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextButton(
                    onPressed: () => unawaited(
                      widget.state.ensureCurrentLyrics(force: true),
                    ),
                    child: const TrText('重新加载歌词'),
                  ),
                  TextButton(
                    key: const ValueKey<String>('import-lyrics'),
                    onPressed: () =>
                        unawaited(pickAndImportLyrics(context, widget.state)),
                    child: const TrText('导入歌词'),
                  ),
                ],
              ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        if (!box.hasBoundedHeight ||
            !box.hasBoundedWidth ||
            box.maxHeight <= 0 ||
            box.maxWidth <= 0) {
          return const SizedBox.shrink();
        }
        _layout(
          Size(box.maxWidth, box.maxHeight),
          MediaQuery.textScalerOf(context),
        );
        _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        return PopScope<void>(
          canPop: !_selection.active,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop && _selection.active) {
              _changeSelection(const LyricSelection());
            }
          },
          child: Stack(
            key: _viewportKey,
            fit: StackFit.expand,
            children: [
              Listener(
                onPointerSignal: _wheel,
                onPointerDown: (event) {
                  if (event.buttons & kMiddleMouseButton != 0) {
                    _middlePointer = event.pointer;
                    _dragging = true;
                    _beginManual();
                  }
                },
                onPointerMove: (event) {
                  if (event.pointer == _middlePointer) {
                    _setOffset(_offset - event.delta.dy);
                  }
                },
                onPointerUp: (event) {
                  if (event.pointer == _middlePointer) {
                    _middlePointer = null;
                    _dragging = false;
                    _scheduleResume();
                  }
                },
                onPointerCancel: (event) {
                  if (event.pointer == _middlePointer) {
                    _middlePointer = null;
                    _dragging = false;
                    _scheduleResume();
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragStart: (_) {
                    _extendingSelection =
                        _selection.active &&
                        _wall.elapsedMilliseconds - _dragArmedAt < 900;
                    if (_extendingSelection) return;
                    _dragging = true;
                    _dragCarry = _velocity;
                    _beginManual();
                  },
                  onVerticalDragUpdate: (event) => _extendingSelection
                      ? _extendSelection(event.globalPosition)
                      : _setOffset(_offset - event.delta.dy),
                  onVerticalDragEnd: (event) {
                    if (_extendingSelection) {
                      _extendingSelection = false;
                      return;
                    }
                    _dragging = false;
                    final released = -event.velocity.pixelsPerSecond.dy;
                    _velocity =
                        released +
                        (released.sign == _dragCarry.sign
                            ? ScrollMotion.carriedVelocity(
                                _dragCarry,
                                acceleration: widget.state.scrollAcceleration,
                              )
                            : 0);
                    _dragCarry = 0;
                    _start();
                    _scheduleResume();
                  },
                  onVerticalDragCancel: () {
                    _extendingSelection = false;
                    _dragCarry = 0;
                    _dragging = false;
                    _scheduleResume();
                  },
                  // The edge mask is built once per layout change, not once
                  // per animation frame: rebuilding the double ShaderMask at
                  // 60 fps reconfigured a full-pane offscreen layer each frame.
                  // Own layer: the moving sheet never dirties the backdrop or
                  // the player controls around it.
                  child: RepaintBoundary(
                    child: _edgeFade(
                      AnimatedBuilder(
                        animation: Listenable.merge([_frames, _blur]),
                        builder: (context, _) => Stack(
                          fit: StackFit.expand,
                          clipBehavior: Clip.none,
                          children: [
                            for (var i = 0; i < _lines.length; i++)
                              if (_ys[i].value + _heights[i] >= -80 &&
                                  _ys[i].value <= _size.height + 80)
                                _positionedRow(i),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: AnimatedSwitcher(
                      duration: AppMotion.standard,
                      reverseDuration: AppMotion.exit,
                      switchInCurve: AppMotion.fadeCurve,
                      switchOutCurve: AppMotion.exitCurve,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, .12),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _selection.active
                          ? LyricSelectionToolbar(
                              key: const ValueKey('lyric-selection-toolbar'),
                              count: _selection.keys.length,
                              copied: _copied,
                              onSelectAll: () =>
                                  _changeSelection(_selection.all(_lines)),
                              onCopy: () => unawaited(_copyLyrics()),
                              onCreateImage: () => unawaited(_createImage()),
                              onClose: () =>
                                  _changeSelection(const LyricSelection()),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _resume?.cancel();
    for (final notifier in _rowFrames) {
      notifier.dispose();
    }
    _copiedTimer?.cancel();
    widget.state.all.removeListener(_onLane);
    LyricFxGovernor.instance.removeListener(_onTier);
    LyricFxGovernor.instance.release(this);
    _ticker?.dispose();
    _blur.dispose();
    _frames.dispose();
    super.dispose();
  }
}
