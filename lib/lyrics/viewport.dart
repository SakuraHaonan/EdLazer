import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'edge_fade.dart';
import 'image_export.dart';
import 'lyric_document.dart';
import 'selection.dart';
import 'selection_bar.dart';
import 'spring.dart';
import 'timed_line.dart';

/// Apple Music/AMLL-style lyric sheet with lazy line mounting, live word
/// painting, manual scroll suspension, selection and image export.
///
/// The public surface stays intentionally small: the viewport consumes the
/// shared [AppState], draws the current lyric document and owns only the
/// reading interaction. Cached line widgets stay independent of the scroll
/// viewport so a long song never materialises the whole lyric column.
class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.state,
    this.onSelectionChanged,
    this.fontSize,
    this.fontWeight,
    this.blurEnabled,
  });

  final AppState state;
  final ValueChanged<bool>? onSelectionChanged;
  final double? fontSize;
  final int? fontWeight;
  final bool? blurEnabled;

  @override
  State<LyricViewport> createState() => _LyricViewportState();
}

class _LyricViewportState extends State<LyricViewport>
    with TickerProviderStateMixin {
  late final Ticker _motionTicker;
  late final Ticker _wordTicker;
  Duration _lastMotionTick = Duration.zero;
  bool _seeking = false;
  double _manualVelocity = 0;
  VelocityTracker? _pointerVelocity;
  Timer? _pollTimer;
  late final AnimationController _blurGate;
  final ValueNotifier<int> _motionTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _brightnessTick = ValueNotifier<int>(0);
  final ValueNotifier<int> _wordTick = ValueNotifier<int>(0);

  /// Never ticked; inactive rows paint a static bright layer, so they must not
  /// re-rasterise (and re-blur) on every word frame.
  final ValueNotifier<int> _idleTick = ValueNotifier<int>(0);
  final Map<int, AnimationController> _brightnessControllers =
      <int, AnimationController>{};
  List<LyricSpring> _scaleSprings = <LyricSpring>[];
  List<LyricSpring> _rowYSprings = <LyricSpring>[];

  List<LyricLine> _lines = const <LyricLine>[];
  bool _hasWordTimings = false;
  int _active = 0;
  String? _trackId;
  (double, int, bool)? _styleSnapshot;
  List<double> _heights = const <double>[];
  List<double> _prefix = const <double>[];
  List<LyricLine>? _measuredLines;
  double _measuredWidth = -1;
  double _measuredFont = -1;
  int _measuredWeight = -1;
  TextScaler? _measuredScaler;
  double _viewportHeight = 0;
  double _rowUnit = 0;

  bool _positioned = false;
  bool _manual = false;
  bool _pointerDown = false;
  double _pointerTravel = 0;
  Timer? _resumeTimer;
  Timer? _wheelTimer;

  LyricSelection _selection = const LyricSelection();
  bool _copied = false;
  Timer? _copiedTimer;

  AppState get _state => widget.state;
  double get _fontSize => widget.fontSize ?? _state.lyricFontSize;
  int get _fontWeight => widget.fontWeight ?? _state.lyricFontWeight;
  bool get _blurEnabled => widget.blurEnabled ?? _state.lyricBlurEnabled;

  @override
  void initState() {
    super.initState();
    _motionTicker = createTicker(_onMotionTick);
    _wordTicker = createTicker(_onWordTick);
    _blurGate = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1,
    );
    _trackId = _state.current?.id;
    _lines = _state.lyrics;
    _hasWordTimings = _lines.any((LyricLine line) => line.words.isNotEmpty);
    _styleSnapshot = (_fontSize, _fontWeight, _blurEnabled);
    _active = _activeAt(_state.precisePosition);
    _rebuildScaleSprings();
    _resetBrightnessControllers();
    _state.all.addListener(_onState);
    if (_state.playing) _startPolling();
  }

  @override
  void didUpdateWidget(covariant LyricViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.all.removeListener(_onState);
      widget.state.all.addListener(_onState);
      _lines = widget.state.lyrics;
      _active = _activeAt(widget.state.precisePosition);
      _rebuildScaleSprings();
      _resetBrightnessControllers();
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _wheelTimer?.cancel();
    _copiedTimer?.cancel();
    _state.all.removeListener(_onState);
    _stopPolling();
    _motionTicker.dispose();
    _wordTicker.dispose();
    _blurGate.dispose();
    _disposeBrightnessControllers();
    _motionTick.dispose();
    _brightnessTick.dispose();
    _wordTick.dispose();
    _idleTick.dispose();
    super.dispose();
  }

  int _activeAt(Duration position) {
    if (_lines.isEmpty) return 0;
    int low = 0;
    int high = _lines.length;
    while (low < high) {
      final int middle = (low + high) ~/ 2;
      if (_lines[middle].time <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? 0 : low - 1;
  }

  void _onState() {
    if (!mounted) return;
    final List<LyricLine> nextLines = _state.lyrics;
    final String? nextTrack = _state.current?.id;
    final (double, int, bool) nextStyle = (
      _fontSize,
      _fontWeight,
      _blurEnabled,
    );
    final bool documentChanged = !identical(nextLines, _lines);
    final bool trackChanged = nextTrack != _trackId;
    final bool styleChanged = nextStyle != _styleSnapshot;
    final int nextActive = _activeAt(_state.precisePosition);
    final bool activeChanged = nextActive != _active;
    var needsBuild = false;

    if (documentChanged || trackChanged) {
      _trackId = nextTrack;
      _lines = nextLines;
      _hasWordTimings = _lines.any((LyricLine line) => line.words.isNotEmpty);
      _selection = const LyricSelection();
      _manual = false;
      _active = nextActive;
      _blurGate.value = 1;
      _positioned = false;
      _rebuildScaleSprings();
      _resetBrightnessControllers();
      if (_motionTicker.isActive) _motionTicker.stop();
      needsBuild = true;
    } else if (activeChanged) {
      _seeking = (nextActive - _active).abs() > 1;
      _active = nextActive;
      _setLineBrightnessActive(nextActive);
      if (!_manual && !_selection.active) {
        _setRowTargets();
        _setScaleTargets();
      }
      needsBuild = true;
    }
    if (styleChanged) {
      _styleSnapshot = nextStyle;
      needsBuild = true;
    }

    if (!_state.playing) {
      _stopPolling();
      if (_active < _lines.length && _lines[_active].words.isNotEmpty) {
        _wordTick.value++;
      }
    } else {
      _startPolling();
    }
    if (needsBuild) setState(() {});
  }

  /// The 8 ms timer only tracks the engine clock for line changes. Word
  /// repaints are driven by [Ticker] so every frame is vsync-aligned; a timer
  /// based repaint pump aliases against the display refresh and makes the
  /// per-glyph float animation visibly stutter.
  void _startPolling() {
    _pollTimer ??= Timer.periodic(const Duration(milliseconds: 8), (_) {
      _pollActiveLine();
    });
    if (_hasWordTimings && _state.playing) {
      if (!_wordTicker.isActive) _wordTicker.start();
    } else if (_wordTicker.isActive) {
      _wordTicker.stop();
    }
  }

  void _pollActiveLine() {
    if (!mounted) {
      _stopPolling();
      return;
    }
    if (!_state.playing) {
      _stopPolling();
      return;
    }
    final int active = _activeAt(_state.precisePosition);
    if (active != _active) {
      _seeking = (active - _active).abs() > 1;
      setState(() => _active = active);
      _setLineBrightnessActive(active);
      if (!_manual && !_selection.active) {
        _setRowTargets();
        _setScaleTargets();
      }
    }
  }

  /// One repaint per displayed frame while word-timed lyrics are playing.
  void _onWordTick(Duration elapsed) {
    if (!mounted || !_state.playing) {
      _stopPolling();
      return;
    }
    if (_active >= 0 &&
        _active < _lines.length &&
        _lines[_active].words.isNotEmpty) {
      _wordTick.value++;
    }
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_wordTicker.isActive) _wordTicker.stop();
  }

  AnimationController _brightnessControllerFor(int index, {double value = 0}) {
    return _brightnessControllers.putIfAbsent(index, () {
      final AnimationController controller = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
        reverseDuration: const Duration(milliseconds: 450),
        value: value,
      );
      controller.addListener(() => _brightnessTick.value++);
      return controller;
    });
  }

  void _disposeBrightnessControllers() {
    for (final AnimationController controller
        in _brightnessControllers.values) {
      controller.dispose();
    }
    _brightnessControllers.clear();
  }

  void _resetBrightnessControllers() {
    _disposeBrightnessControllers();
    if (_lines.isEmpty) return;
    final int active = _active.clamp(0, _lines.length - 1);
    _brightnessControllerFor(active, value: 1);
  }

  void _setLineBrightnessActive(int active) {
    if (_lines.isEmpty) return;
    for (final MapEntry<int, AnimationController> entry
        in _brightnessControllers.entries) {
      if (entry.key == active) continue;
      final AnimationController controller = entry.value;
      if (controller.value > 0) {
        controller.animateTo(
          0,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
        );
      }
    }
    final AnimationController current = _brightnessControllerFor(active);
    current.animateTo(
      1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  double _brightnessFor(int index) {
    final double normal = _brightnessControllers[index]?.value ?? 0;
    if (_selection.active) {
      final bool selected = _selection.keys.contains(
        lyricSelectionKey(_lines[index]),
      );
      // Selection only raises the selected rows to full alpha; every other
      // row keeps exactly the brightness it had before selection began.
      return selected ? 1 : normal;
    }
    return normal;
  }

  void _rebuildScaleSprings() {
    _scaleSprings = <LyricSpring>[
      for (var i = 0; i < _lines.length; i++)
        LyricSpring(
          i == _active ? 100 : 97,
          params: const LyricSpringParams(mass: 2, damping: 25, stiffness: 100),
        ),
    ];
    _rowYSprings = <LyricSpring>[
      for (var i = 0; i < _lines.length; i++) LyricSpring(0),
    ];
  }

  void _startMotion() {
    _lastMotionTick = Duration.zero;
    if (!_motionTicker.isActive) _motionTicker.start();
  }

  List<double> _lineYDelays(int active) {
    final List<double> positions = _heights.length == _lines.length
        ? <double>[
            for (var i = 0; i < _lines.length; i++)
              _prefix[i] - _prefix[active],
          ]
        : <double>[for (var i = 0; i < _lines.length; i++) (i - active) * 80];
    final List<double> heights = _heights.length == _lines.length
        ? _heights
        : List<double>.filled(_lines.length, 80);
    return lyricStaggerDelays(
      positions,
      heights,
      active,
      disabled: _seeking || _manual || MediaQuery.disableAnimationsOf(context),
    );
  }

  double _targetYFor(int index, int active) {
    final double activeTop = _viewportHeight * .35 - _heights[active] / 2;
    return activeTop + (_prefix[index] - _prefix[active]);
  }

  void _setRowTargets({bool snap = false}) {
    if (_heights.length != _lines.length || _viewportHeight <= 0) return;
    if (_rowYSprings.length != _lines.length) _rebuildScaleSprings();
    final int active = _active.clamp(0, _lines.length - 1);
    final Track? track = _state.current;
    final bool endOfSong =
        track != null &&
        track.duration > Duration.zero &&
        _state.position >= track.duration;
    final LyricSpringParams params = lyricPositionPolicy(
      seeking: _seeking,
      intervalMs: _lyricIntervalMs(),
      endOfSong: endOfSong,
    );
    final List<double> delays = snap
        ? List<double>.filled(_lines.length, 0)
        : _lineYDelays(active);
    final bool immediate =
        snap || _seeking || _manual || MediaQuery.disableAnimationsOf(context);
    // The focus row must start rising on the same frame it becomes active.
    // AMLL's stagger schedule otherwise queues it behind the rows above, so
    // the blur/scale/word animations lead the float by one step.
    if (!immediate) delays[active] = 0;
    for (var i = 0; i < _rowYSprings.length; i++) {
      final LyricSpring spring = _rowYSprings[i];
      spring.setParameters(params);
      final double target = _targetYFor(i, active);
      if (immediate) {
        spring.setPosition(target);
      } else {
        spring.setTarget(target, delay: delays[i]);
      }
    }
    if (!immediate) _startMotion();
  }

  void _setScaleTargets() {
    if (_scaleSprings.length != _lines.length) _rebuildScaleSprings();
    if (_scaleSprings.isEmpty) {
      _motionTicker.stop();
      return;
    }
    final int active = _active.clamp(0, _lines.length - 1);
    for (var i = 0; i < _scaleSprings.length; i++) {
      final LyricSpring spring = _scaleSprings[i];
      spring
        ..setParameters(
          const LyricSpringParams(mass: 2, damping: 25, stiffness: 100),
        )
        ..setTarget(i == active ? 100 : 97);
    }
    _startMotion();
  }

  int? _lyricIntervalMs() {
    if (_active <= 0 || _active >= _lines.length) {
      if (_lines.length < 2) return null;
      return (_lines[1].time - _lines[0].time).inMilliseconds;
    }
    return (_lines[_active].time - _lines[_active - 1].time).inMilliseconds;
  }

  void _onMotionTick(Duration elapsed) {
    if (!mounted) {
      _motionTicker.stop();
      return;
    }
    if (_lastMotionTick == Duration.zero) {
      _lastMotionTick = elapsed;
      return;
    }
    final double dt = ((elapsed - _lastMotionTick).inMicroseconds / 1e6).clamp(
      0.0,
      .05,
    );
    _lastMotionTick = elapsed;
    var moving = false;
    if (_manual) {
      if (_manualVelocity.abs() > 5) {
        final double deltaY = _manualVelocity * dt;
        final double moved = _shiftRows(deltaY);
        if (moved.abs() < deltaY.abs() - .001) {
          _manualVelocity = 0;
        } else {
          _manualVelocity *= math
              .pow(_state.scrollRetention, dt * 60)
              .toDouble();
        }
        moving = _manualVelocity.abs() > 5;
      }
    } else {
      for (final LyricSpring spring in _rowYSprings) {
        spring.update(dt);
        moving = moving || !spring.arrived;
      }
      for (final LyricSpring spring in _scaleSprings) {
        spring.update(dt);
        moving = moving || !spring.arrived;
      }
      _motionTick.value++;
    }
    if (!moving) {
      _seeking = false;
      _motionTicker.stop();
    }
  }

  /// Clamp manual content movement to the first/last lyric.
  ///
  /// The top limit pins the first line to the focus band; the bottom limit
  /// pins the last line there as well. This is the same safe scroll interval
  /// AMLL's LayoutCalculator exposes to its scroll engine.
  double _shiftRows(double requested) {
    if (_rowYSprings.isEmpty ||
        _rowYSprings.length != _heights.length ||
        _viewportHeight <= 0) {
      return 0;
    }
    final double focusY = _viewportHeight * .35;
    final double maxShift =
        focusY - _heights.first / 2 - _rowYSprings.first.value;
    final double minShift =
        focusY - _heights.last / 2 - _rowYSprings.last.value;
    if (minShift > maxShift) return 0;
    final double shift = requested.clamp(minShift, maxShift);
    if (shift.abs() < .001) return 0;
    for (final LyricSpring spring in _rowYSprings) {
      spring.setPosition(spring.value + shift);
    }
    _motionTick.value++;
    return shift;
  }

  void _beginManual() {
    if (_manual) return;
    _resumeTimer?.cancel();
    if (_motionTicker.isActive) _motionTicker.stop();
    setState(() => _manual = true);
    _blurGate.animateTo(0, curve: Curves.easeOutCubic);
  }

  void _scheduleResume({Duration? after}) {
    _resumeTimer?.cancel();
    final Duration delay =
        after ??
        Duration(milliseconds: (_state.lyricResumeSeconds * 1000).round());
    _resumeTimer = Timer(delay, () {
      if (!mounted || _selection.active) return;
      setState(() => _manual = false);
      _manualVelocity = 0;
      _blurGate.animateTo(1, curve: Curves.easeOutCubic);
      _setRowTargets();
      _setScaleTargets();
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _pointerTravel = 0;
    _pointerVelocity = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.position);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerDown) return;
    _pointerTravel += event.delta.distance;
    _pointerVelocity?.addPosition(event.timeStamp, event.position);
    if (_pointerTravel > 6 && !_manual) _beginManual();
    if (_manual) {
      _manualVelocity = 0;
      _shiftRows(event.delta.dy);
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_pointerDown) return;
    _pointerDown = false;
    final Velocity? velocity = _pointerVelocity?.getVelocity();
    _pointerVelocity = null;
    if (_manual) {
      final double dy = velocity?.pixelsPerSecond.dy ?? 0;
      if (dy.abs() > 40) {
        _manualVelocity = dy;
        _lastMotionTick = Duration.zero;
        if (!_motionTicker.isActive) _motionTicker.start();
      } else {
        _manualVelocity = 0;
      }
      _scheduleResume();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerDown = false;
    _pointerVelocity = null;
    _manualVelocity = 0;
    if (_manual) _scheduleResume();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _resumeTimer?.cancel();
    _beginManual();
    final double delta = _shiftRows(-event.scrollDelta.dy);
    _manualVelocity = delta * 18;
    _lastMotionTick = Duration.zero;
    if (!_motionTicker.isActive) _motionTicker.start();
    _motionTick.value++;
    _wheelTimer?.cancel();
    _wheelTimer = Timer(
      const Duration(milliseconds: 820),
      () => _scheduleResume(),
    );
  }

  void _seekTo(int index) {
    final Track? track = _state.current;
    if (track == null || track.duration <= Duration.zero) return;
    final double fraction =
        (_lines[index].time.inMilliseconds / track.duration.inMilliseconds)
            .clamp(0.0, 1.0);
    _seeking = true;
    _state.seek(fraction);
    _wordTick.value++;
  }

  void _beginSelection(int index) {
    _resumeTimer?.cancel();
    if (_motionTicker.isActive) _motionTicker.stop();
    setState(() {
      _selection = _selection.begin(_lines, index);
      _manual = true;
    });
    _blurGate.animateTo(0, curve: Curves.easeOutCubic);
    widget.onSelectionChanged?.call(_selection.active);
  }

  void _toggleSelection(int index) {
    setState(() => _selection = _selection.toggle(_lines, index));
    widget.onSelectionChanged?.call(_selection.active);
  }

  void _selectAll() {
    setState(() => _selection = _selection.all(_lines));
    widget.onSelectionChanged?.call(true);
  }

  void _closeSelection() {
    setState(() {
      _selection = const LyricSelection();
      _manual = false;
    });
    widget.onSelectionChanged?.call(false);
    _blurGate.animateTo(1, curve: Curves.easeOutCubic);
    _setRowTargets();
    _setScaleTargets();
  }

  Future<void> _copySelection() async {
    await Clipboard.setData(ClipboardData(text: _selection.text(_lines)));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedTimer?.cancel();
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _exportSelection() async {
    final Track? track = _state.current;
    if (track == null) return;
    final List<LyricLine> selected = <LyricLine>[
      for (final LyricLine line in _lines)
        if (_selection.keys.contains(lyricSelectionKey(line))) line,
    ];
    if (selected.isEmpty) return;
    await showLyricImageDialog(context, track: track, lines: selected);
  }

  TextStyle _mainStyle(BuildContext context) {
    final int weightIndex = ((_fontWeight ~/ 100) - 1).clamp(0, 8);
    return Theme.of(context).textTheme.bodyLarge!.copyWith(
      fontSize: _fontSize,
      height: 1.5,
      fontWeight: FontWeight.values[weightIndex],
      color: Theme.of(context).colorScheme.onSurface,
    );
  }

  String get _semanticLabel {
    if (_selection.active) return '已选择 ${_selection.keys.length} 行歌词';
    if (_lines.isEmpty) return '歌词';
    final int index = _active.clamp(0, _lines.length - 1);
    final LyricLine line = _lines[index];
    final String? translation = line.translation?.trim();
    return translation == null || translation.isEmpty
        ? line.text
        : '${line.text}\n$translation';
  }

  TextStyle _translationStyle(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall!.copyWith(
      fontSize: (_fontSize * 16 / 22).clamp(12, 30),
      height: 1.45,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      // A soft halo keeps the quieter translation readable over the cover
      // wash. It is painted outside the row's colour filter, which would
      // otherwise dye the shadow the same colour as the glyphs.
      shadows: const <Shadow>[
        Shadow(color: Color(0xE6000000), blurRadius: 10),
        Shadow(color: Color(0x99000000), blurRadius: 3, offset: Offset(0, 1)),
      ],
    );
  }

  double _emphasisFor(int index) {
    if (index < 0 || index >= _scaleSprings.length) return 0;
    return ((_scaleSprings[index].value - 97) / 3).clamp(0.0, 1.0);
  }

  double _sigmaFor(int index) {
    if (!_blurEnabled ||
        _blurGate.value <= 0.001 ||
        _rowUnit <= 0 ||
        index >= _rowYSprings.length ||
        index >= _heights.length) {
      return 0;
    }
    // Derive blur from the row's actual spring position instead of its index:
    // a row stays soft until it physically arrives in the 35% focus band, so
    // the blur clears exactly in step with the upward float rather than
    // finishing ahead of it.
    final double centre = _rowYSprings[index].value + _heights[index] * 0.5;
    final double distance = (centre - _viewportHeight * .35).abs() / _rowUnit;
    final double gate = Curves.easeOutCubic.transform(_blurGate.value);
    return (math.min(5.0, distance * 1.55) * gate).clamp(0.0, 5.0);
  }

  double _scaleFor(int index) {
    if (index < 0 || index >= _scaleSprings.length) return .97;
    return _scaleSprings[index].value / 100;
  }

  Color _toneFor(int index, ThemeData theme) {
    if (_selection.active) {
      final bool selected = _selection.keys.contains(
        lyricSelectionKey(_lines[index]),
      );
      // The long-press highlight is plain bright white, not the theme accent.
      return selected ? Colors.white : theme.colorScheme.onSurface;
    }
    // Line depth is produced by the AMLL bright/dim brightness layers, not by
    // changing the semantic text colour per line.
    return theme.colorScheme.onSurface;
  }

  Widget _interactive(int index, String text, TextStyle style, Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selection.active ? _toggleSelection(index) : _seekTo(index),
      onLongPress: () => _beginSelection(index),
      child: child,
    );
  }

  Widget _rowBody(int index, ThemeData theme) {
    final LyricLine line = _lines[index];
    final TextStyle style = _mainStyle(context);
    final double brightness = _brightnessFor(index).clamp(0.0, 1.0);
    final Widget brightMain = line.words.isNotEmpty
        ? TimedLyricText(
            line: line,
            style: style,
            active: index == _active,
            emphasis: () => _emphasisFor(index),
            position: () => _state.precisePosition,
            repaint: index == _active ? _wordTick : _idleTick,
          )
        : Text(
            line.text.isEmpty ? ' ' : line.text,
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
            style: style,
          );
    // AMLL LineBrightness: the dim copy is a plain, unmasked clone at 0.2
    // opacity; the bright original cross-fades above it. The timed painter
    // keeps its own 0.4 dark-mask content for unsung words inside the bright
    // layer, so no second animated copy is needed.
    final Widget dimMain = IgnorePointer(
      // RichText keeps the dim clone out of `find.text`/selection hit targets
      // while matching the exact layout of the bright line.
      child: RichText(
        textAlign: TextAlign.left,
        textDirection: TextDirection.ltr,
        text: TextSpan(text: line.text.isEmpty ? ' ' : line.text, style: style),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _interactive(
          index,
          line.text,
          style,
          SizedBox(
            key: ValueKey<String>('lyric-main-$index'),
            width: double.infinity,
            child: Stack(
              children: <Widget>[
                Opacity(
                  key: ValueKey<String>('lyric-dim-$index'),
                  opacity: .2 * (1 - brightness),
                  child: dimMain,
                ),
                Opacity(
                  key: ValueKey<String>('lyric-bright-$index'),
                  opacity: brightness,
                  child: brightMain,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(int index, ThemeData theme) {
    final double sigma = _sigmaFor(index);
    final Color tone = _toneFor(index, theme);
    final LyricLine line = _lines[index];
    final String? translation = line.translation?.trim();
    final bool translationSelected =
        _selection.active && _selection.keys.contains(lyricSelectionKey(line));
    return SizedBox(
      key: ValueKey<String>('lyric-line-${_state.current?.id}-$index'),
      height: _heights[index],
      child: Transform.scale(
        scale: _scaleFor(index),
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ImageFiltered(
              key: ValueKey<String>('lyric-blur-$index'),
              enabled: sigma > .02,
              imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: ColorFiltered(
                key: ValueKey<String>('lyric-color-$index'),
                colorFilter: ColorFilter.mode(tone, BlendMode.srcIn),
                child: RepaintBoundary(child: _rowBody(index, theme)),
              ),
            ),
            // The translation stays outside the depth blur so its halo reads
            // as a real shadow instead of smearing into the cover wash.
            if (translation != null && translation.isNotEmpty) ...<Widget>[
              const SizedBox(height: 5),
              _interactive(
                index,
                translation,
                _translationStyle(context),
                Opacity(
                  key: ValueKey<String>('lyric-translation-$index'),
                  opacity: translationSelected ? 1 : .72,
                  child: Text(
                    translation,
                    textAlign: TextAlign.left,
                    textDirection: TextDirection.ltr,
                    style: _translationStyle(context),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _measureLines(BuildContext context, double width) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    if (identical(_measuredLines, _lines) &&
        _measuredWidth == width &&
        _measuredFont == _fontSize &&
        _measuredWeight == _fontWeight &&
        _measuredScaler == scaler) {
      return;
    }
    _measuredLines = _lines;
    _measuredWidth = width;
    _measuredFont = _fontSize;
    _measuredWeight = _fontWeight;
    _measuredScaler = scaler;
    final TextStyle main = _mainStyle(context);
    final TextStyle translation = _translationStyle(context);
    final double textWidth = math.max(1, width - 36);
    final List<double> heights = <double>[];
    final List<double> prefix = <double>[];
    var sum = 0.0;
    for (final LyricLine line in _lines) {
      final double mainHeight = _measureText(
        line.text,
        main,
        textWidth,
        scaler,
      );
      final String? translated = line.translation?.trim();
      final double translatedHeight = translated == null || translated.isEmpty
          ? 0
          : 5 + _measureText(translated, translation, textWidth, scaler);
      final double height = math.max(52, mainHeight + translatedHeight + 20);
      prefix.add(sum);
      heights.add(height);
      sum += height;
    }
    _heights = heights;
    _prefix = prefix;
    _rowUnit = heights.isEmpty ? 0 : sum / heights.length;
    _positioned = false;
  }

  double _measureText(
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final double height = painter.height;
    painter.dispose();
    return height;
  }

  Widget _empty(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_state.lyricsLoading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _state.lyricsError ??
                  (_state.lyricsPureMusic ? '纯音乐' : '这首歌暂未提供歌词'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (!_state.lyricsPureMusic) ...<Widget>[
              const SizedBox(height: 10),
              TextButton(
                onPressed: () =>
                    unawaited(_state.ensureCurrentLyrics(force: true)),
                child: const Text('重新加载歌词'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _lineStack(BoxConstraints constraints, ThemeData theme) {
    if (_heights.length != _lines.length ||
        _rowYSprings.length != _lines.length) {
      _rebuildScaleSprings();
      _setRowTargets(snap: true);
    }
    // AMLL keeps a 40% motion buffer around the viewport so fast springs do
    // not reveal a row only after it has already entered the visible frame.
    final double overscan = 72 + constraints.maxHeight * .4;
    final double width = math.max(0, constraints.maxWidth - 36);
    final Widget stack = Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        for (var i = 0; i < _lines.length; i++)
          if (_rowYSprings[i].value + _heights[i] >= -overscan &&
              _rowYSprings[i].value <= constraints.maxHeight + overscan)
            Positioned(
              key: ValueKey<String>('lyric-position-$i'),
              top: _rowYSprings[i].value,
              left: 18,
              width: width,
              height: _heights[i],
              child: _row(i, theme),
            ),
      ],
    );
    return LyricEdgeFade(
      verticalExtent: _blurEnabled
          ? math.min(constraints.maxHeight * .18, 64)
          : math.min(constraints.maxHeight * .11, 44),
      horizontal: _blurEnabled,
      child: stack,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (_lines.isEmpty) return _empty(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedWidth ||
            !constraints.hasBoundedHeight ||
            constraints.maxWidth <= 0 ||
            constraints.maxHeight <= 0) {
          return const SizedBox.shrink();
        }
        _measureLines(context, constraints.maxWidth);
        _viewportHeight = constraints.maxHeight;
        if (_active >= _lines.length) _active = _lines.length - 1;
        if (!_positioned) {
          _positioned = true;
          _setRowTargets(snap: true);
        }

        return PopScope<void>(
          canPop: !_selection.active,
          onPopInvokedWithResult: (bool didPop, Object? result) {
            if (!didPop && _selection.active) _closeSelection();
          },
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Semantics(
                key: const ValueKey<String>('lyric-live-region'),
                container: true,
                liveRegion: true,
                label: _semanticLabel,
                child: ExcludeSemantics(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    onPointerSignal: _onPointerSignal,
                    child: AnimatedBuilder(
                      animation: Listenable.merge(<Listenable>[
                        _motionTick,
                        _brightnessTick,
                        _blurGate,
                      ]),
                      builder: (BuildContext context, Widget? _) =>
                          _lineStack(constraints, theme),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder:
                          (Widget child, Animation<double> animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, .3),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                      child: _selection.active
                          ? LyricSelectionToolbar(
                              key: const ValueKey<String>(
                                'lyric-selection-toolbar',
                              ),
                              count: _selection.keys.length,
                              copied: _copied,
                              onSelectAll: _selectAll,
                              onCopy: () => unawaited(_copySelection()),
                              onCreateImage: () =>
                                  unawaited(_exportSelection()),
                              onClose: _closeSelection,
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
}
