import 'package:lazer_nextgen/theme/app_palette.dart';
// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../animation/lyric_spring.dart';
import '../data/lyrics.dart';
import '../data/lyric_selection.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import 'lyric_selection_toolbar.dart';
import 'lyric_image_dialog.dart';
import 'lyric_edge_fade.dart';
import 'timed_lyric_text.dart';

/// children stay cached while the ticker only updates their transforms.
class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.state,
    this.onSelectionChanged,
    this.onLineTap,
  });
  final AppState state;
  final ValueChanged<bool>? onSelectionChanged;

  /// Veto over a tap on a line while nothing is selected. Returning true
  /// swallows the tap; the viewport only seeks when the host declines.
  final bool Function(int index, bool isCurrentLine)? onLineTap;
  @override
  State<LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<LyricViewport>
    with TickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  late final AnimationController _blur = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
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
  List<Widget> _rows = [];
  Size _size = Size.zero;
  double get _gutter =>
      math.min(LyricEdgeFade.horizontalExtent, _size.width * 0.1);
  double get _textWidth => math.max(1.0, _size.width - _gutter * 2);
  TextScaler? _textScaler;
  int _active = -1;
  bool _playing = false;
  bool _manual = false;
  bool _dragging = false;
  int? _middlePointer;
  double _offset = 0;
  double _velocity = 0;
  Duration _lastFrame = Duration.zero;
  Duration? _lastMedia;
  int _lastWall = 0;
  Timer? _resume;
  Timer? _followClock;
  bool _clockVisible = true;
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
    widget.state.all.addListener(_onLane);
  }

  @override
  void didUpdateWidget(covariant LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.all.removeListener(_onLane);
      widget.state.all.addListener(_onLane);
    }
    _updateBlur();
    _syncFollowClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _clockVisible = TickerMode.valuesOf(context).enabled;
    _syncFollowClock();
  }

  void _syncFollowClock() {
    if (!widget.state.playing ||
        !_clockVisible ||
        widget.state.lyrics.isEmpty) {
      _followClock?.cancel();
      _followClock = null;
      return;
    }
    _followClock ??= Timer.periodic(
      AppState.lyricFollowInterval,
      (_) => _followLine(),
    );
  }

  void _followLine() {
    if (!mounted || !identical(_lines, widget.state.lyrics) || _lines.isEmpty) {
      return;
    }
    final active = _activeAt(widget.state.precisePosition);
    if (active == _active) return;
    setState(() {
      _active = active;
      _rows = [];
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
    if (changed || active != _active || _playing != widget.state.playing) {
      setState(() {
        _active = active;
        _playing = widget.state.playing;
        _rows = [];
        if (!changed && !_manual) _targets(seeking: seeking);
        _scaleTargets();
      });
    }
    // Paused seeks within one line still change the word mask.
    _frames.value++;
    _updateBlur();
    _syncFollowClock();
  }

  void _updateBlur() {
    final target = widget.state.lyricBlurEnabled && !_manual ? 1.0 : 0.0;
    if (_blurTarget != target) {
      _blurTarget = target;
      _blur.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  /// Blur tracks how far a row sits from the focus band instead of its index
  /// gap, so it ramps in and out as rows travel rather than snapping to zero
  /// the instant a line becomes active.
  double _sigma(int i) {
    if (_rowUnit <= 0 || _blur.value <= 0) return 0;
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
    child: child,
  );

  void _start() {
    if (!_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
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
    _frames.value++;
    if (!moving) _ticker.stop();
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
    final params = lyricPositionPolicy(
      seeking: seeking,
      intervalMs: focus > 0
          ? (_lines[focus].time - _lines[focus - 1].time).inMilliseconds
          : null,
      endOfSong:
          widget.state.position >=
          (widget.state.current?.duration ?? const Duration(days: 1)),
    );
    final delays = lyricStaggerDelays(
      positions,
      _heights,
      focus,
      disabled: seeking || !stagger,
    );
    for (var i = 0; i < _ys.length; i++) {
      _ys[i].setParameters(params);
      _ys[i].setTarget(positions[i], delay: delays[i]);
    }
    _scaleTargets();
    _start();
  }

  TextStyle get _originalStyle => context.type.bodySm.copyWith(
    fontSize: 22,
    height: 1.5,
    fontWeight: FontWeight.w600,
  );
  TextStyle get _translationStyle => context.type.bodySm.copyWith(
    fontSize: 16,
    height: 1.45,
    color: context.colors.cloudDark,
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
    if (!replaced && size == _size && scaler == _textScaler) return;
    final needsMeasure =
        replaced || size.width != _size.width || scaler != _textScaler;
    _size = size;
    _textScaler = scaler;
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
      _rows = [];
    }
    if (replaced) {
      _ys = [
        for (var i = 0; i < _lines.length; i++) LyricSpring(size.height * 2),
      ];
      _scales = [
        for (var i = 0; i < _lines.length; i++)
          LyricSpring(
            i == _active ? 100 : 97,
            params: const LyricSpringParams(
              mass: 2,
              damping: 25,
              stiffness: 100,
            ),
          ),
      ];
      _manual = _selection.active;
    }
    if (_manual) {
      _setOffset(_offset);
    } else {
      _targets(stagger: false);
    }
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
      _velocity = ScrollMotion.addWheelImpulse(_velocity, event.scrollDelta.dy);
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
    if (widget.onLineTap?.call(index, index == _active) ?? false) return;
    _seek(index);
  }

  void _changeSelection(LyricSelection next, {bool resume = true}) {
    final changed = _selection.active != next.active;
    setState(() {
      _selection = next;
      _selectionRevision++;
      _copied = false;
      _rows = [];
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
    await showLyricImageDialog(context, track: track, lines: selected);
  }

  Widget _row(int index) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _selection.active
        ? _changeSelection(_selection.toggle(_lines, index))
        : _tapLine(index),
    onLongPress: () => _selectLyrics(index),
    onLongPressMoveUpdate: (event) => _extendSelection(event.globalPosition),
    onLongPressEnd: (_) => _dragArmedAt = _wall.elapsedMilliseconds,
    child: Semantics(
      selected: _selection.active
          ? _selection.keys.contains(lyricSelectionKey(_lines[index]))
          : null,
      child: TweenAnimationBuilder<double>(
        tween: Tween(
          end: _selection.keys.contains(lyricSelectionKey(_lines[index]))
              ? 1
              : 0,
        ),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, selected, _) => AnimatedOpacity(
          opacity: _selection.active ? 0.54 + selected * 0.46 : 1,
          duration: const Duration(milliseconds: 180),
          child: _rowBody(index, selected),
        ),
      ),
    ),
  );

  Widget _rowBody(int index, double selected) {
    final focused = index == _active;
    double emphasis() => ((_scales[index].value - 97) / 3).clamp(0.0, 1.0);
    final style = _originalStyle.copyWith(color: context.colors.slateDark);
    return SizedBox(
      width: _textWidth,
      height: _heights[index],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedBuilder(
            animation: _frames,
            builder: (context, child) => ColorFiltered(
              key: ValueKey('lyric-color-$index'),
              colorFilter: ColorFilter.mode(
                Color.lerp(
                  Color.lerp(
                    context.colors.cloudDark,
                    context.colors.slateDark,
                    emphasis(),
                  ),
                  context.colors.clayDeep,
                  selected * .65,
                )!,
                BlendMode.srcIn,
              ),
              child: child,
            ),
            child: _lines[index].words.isNotEmpty
                ? TimedLyricText(
                    line: _lines[index],
                    style: style,
                    active: focused,
                    emphasis: emphasis,
                    position: () => widget.state.precisePosition,
                    repaint: _frames,
                  )
                : Text(
                    _lines[index].text.isEmpty ? ' ' : _lines[index].text,
                    textAlign: TextAlign.left,
                    textDirection: TextDirection.ltr,
                    style: style,
                  ),
          ),
          if (_lines[index].translation != null) ...[
            const SizedBox(height: 5),
            Text(
              _lines[index].translation!,
              textAlign: TextAlign.left,
              textDirection: TextDirection.ltr,
              style: _translationStyle.copyWith(
                color: Color.lerp(
                  context.colors.cloudDark,
                  context.colors.clayDeep,
                  selected * .65,
                ),
              ),
            ),
          ],
        ],
      ),
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
              TextButton(
                onPressed: () =>
                    unawaited(widget.state.ensureCurrentLyrics(force: true)),
                child: const TrText('重新加载歌词'),
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
        if (_rows.isEmpty) {
          _rows = [for (var i = 0; i < _lines.length; i++) _row(i)];
        }
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
                            ? ScrollMotion.carriedVelocity(_dragCarry)
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
                  child: AnimatedBuilder(
                    animation: Listenable.merge([_frames, _blur]),
                    builder: (context, _) => _edgeFade(
                      Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          for (var i = 0; i < _lines.length; i++)
                            if (_ys[i].value + _heights[i] >= -80 &&
                                _ys[i].value <= _size.height + 80)
                              Positioned(
                                key: ValueKey(
                                  'lyric-line-${widget.state.current?.id}-$i',
                                ),
                                top: 0,
                                left: _gutter,
                                width: _textWidth,
                                height: _heights[i],
                                child: Transform.translate(
                                  offset: Offset(0, _ys[i].value),
                                  child: Transform.scale(
                                    scale: _scales[i].value / 100,
                                    alignment: Alignment.centerLeft,
                                    child: ImageFiltered(
                                      key: ValueKey('lyric-blur-$i'),
                                      enabled: _sigma(i) > 0.02,
                                      imageFilter: ui.ImageFilter.blur(
                                        sigmaX: _sigma(i),
                                        sigmaY: _sigma(i),
                                      ),
                                      child: _rows[i],
                                    ),
                                  ),
                                ),
                              ),
                        ],
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
                      duration: const Duration(milliseconds: 260),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, .35),
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
    _followClock?.cancel();
    _copiedTimer?.cancel();
    widget.state.all.removeListener(_onLane);
    _ticker.dispose();
    _blur.dispose();
    _frames.dispose();
    super.dispose();
  }
}
