import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
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
  late final ScrollController _scroll;
  late final Ticker _motionTicker;
  late final LyricSpring _scrollSpring;
  Duration _lastMotionTick = Duration.zero;
  Timer? _pollTimer;
  late final AnimationController _focus;
  late final AnimationController _blurGate;
  final ValueNotifier<int> _wordTick = ValueNotifier<int>(0);

  List<LyricLine> _lines = const <LyricLine>[];
  int _active = 0;
  int _previousActive = -1;
  String? _trackId;
  (double, int, bool)? _styleSnapshot;
  List<double> _heights = const <double>[];
  List<double> _prefix = const <double>[];
  List<LyricLine>? _measuredLines;
  double _measuredWidth = -1;
  double _measuredFont = -1;
  int _measuredWeight = -1;
  TextScaler? _measuredScaler;

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
    _scroll = ScrollController();
    _scrollSpring = LyricSpring(0, params: lyricPositionPolicy());
    _motionTicker = createTicker(_onMotionTick);
    _focus = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    _blurGate = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1,
    );
    _trackId = _state.current?.id;
    _lines = _state.lyrics;
    _styleSnapshot = (_fontSize, _fontWeight, _blurEnabled);
    _active = _activeAt(_state.precisePosition);
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
    _focus.dispose();
    _blurGate.dispose();
    _scroll.dispose();
    _wordTick.dispose();
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
      _selection = const LyricSelection();
      _manual = false;
      _previousActive = -1;
      _active = nextActive;
      _focus.value = 1;
      _blurGate.value = 1;
      _positioned = false;
      _scrollSpring.setPosition(_scroll.hasClients ? _scroll.offset : 0);
      needsBuild = true;
    } else if (activeChanged) {
      _previousActive = _active;
      _active = nextActive;
      _focus.forward(from: 0);
      if (!_manual && !_selection.active) _scheduleCenter();
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

  void _startPolling() {
    if (_pollTimer != null) return;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 8), (_) {
      if (!mounted) return;
      if (!_state.playing) {
        _stopPolling();
        return;
      }
      final int active = _activeAt(_state.precisePosition);
      if (active != _active) {
        _previousActive = _active;
        setState(() => _active = active);
        _focus.forward(from: 0);
        if (!_manual && !_selection.active) _scheduleCenter();
      }
      if (_active >= 0 &&
          _active < _lines.length &&
          _lines[_active].words.isNotEmpty) {
        _wordTick.value++;
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _scheduleCenter({bool animate = true}) {
    if (_manual || _selection.active) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _manual || _selection.active) {
        return;
      }
      final double target = _scrollTargetFor(_active).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      );
      if ((_scroll.offset - target).abs() < .5 && !_motionTicker.isActive) {
        return;
      }
      if (!animate || MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(target);
        _scrollSpring.setPosition(target);
        if (_motionTicker.isActive) _motionTicker.stop();
        return;
      }
      if (!_motionTicker.isActive &&
          (_scrollSpring.value - _scroll.offset).abs() > .5) {
        _scrollSpring.setPosition(_scroll.offset);
      }
      final int? interval = _lyricIntervalMs();
      _scrollSpring
        ..setParameters(lyricPositionPolicy(intervalMs: interval))
        ..setTarget(target);
      _lastMotionTick = Duration.zero;
      if (!_motionTicker.isActive) _motionTicker.start();
    });
  }

  double _scrollTargetFor(int index) {
    if (_heights.isEmpty) return 0;
    final int focus = index.clamp(0, _heights.length - 1);
    return _prefix[focus] + (_heights[focus] - _heights.first) / 2;
  }

  int? _lyricIntervalMs() {
    if (_active <= 0 || _active >= _lines.length) {
      if (_lines.length < 2) return null;
      return (_lines[1].time - _lines[0].time).inMilliseconds;
    }
    return (_lines[_active].time - _lines[_active - 1].time).inMilliseconds;
  }

  void _onMotionTick(Duration elapsed) {
    if (!mounted || !_scroll.hasClients) {
      _motionTicker.stop();
      return;
    }
    if (_lastMotionTick == Duration.zero) {
      _lastMotionTick = elapsed;
      return;
    }
    final double dt = ((elapsed - _lastMotionTick).inMicroseconds / 1e6)
        .clamp(0.0, .05);
    _lastMotionTick = elapsed;
    _scrollSpring.update(dt);
    final double offset = _scrollSpring.value.clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    _scroll.jumpTo(offset);
    if (_scrollSpring.arrived) {
      _scrollSpring.setPosition(offset);
      _motionTicker.stop();
    }
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
    final Duration delay = after ??
        Duration(
          milliseconds: (_state.lyricResumeSeconds * 1000).round(),
        );
    _resumeTimer = Timer(delay, () {
      if (!mounted || _selection.active) return;
      setState(() => _manual = false);
      _blurGate.animateTo(1, curve: Curves.easeOutCubic);
      _scheduleCenter();
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerDown = true;
    _pointerTravel = 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerDown) return;
    _pointerTravel += event.delta.distance;
    if (_pointerTravel > 6) _beginManual();
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_pointerDown) return;
    _pointerDown = false;
    if (_manual) _scheduleResume();
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _pointerDown = false;
    if (_manual) _scheduleResume();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    _beginManual();
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
        (_lines[index].time.inMilliseconds /
                track.duration.inMilliseconds)
            .clamp(0.0, 1.0);
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
    _scheduleCenter();
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
    );
  }

  double _sigmaFor(int index) {
    if (!_blurEnabled || _blurGate.value <= 0.001) return 0;
    final double gate = Curves.easeOutCubic.transform(_blurGate.value);
    final double focus = Curves.easeOutCubic.transform(
      _focus.value.clamp(0.0, 1.0),
    );
    double base;
    if (index == _active) {
      base = 1.55 * (1 - focus);
    } else if (index == _previousActive) {
      base = 1.55 * focus;
    } else {
      final int distance = (index - _active).abs().clamp(1, 6);
      base = math.min(4.5, distance * 1.55);
    }
    return (base * gate).clamp(0.0, 4.5);
  }

  double _scaleFor(int index) {
    final double t = _focus.value.clamp(0.0, 1.0);
    if (index == _active) {
      return .97 + .03 * Curves.easeOutCubic.transform(t);
    }
    if (index == _previousActive) {
      return 1 - .03 * Curves.easeInCubic.transform(t);
    }
    return .97;
  }



  Color _toneFor(int index, ThemeData theme) {
    final bool selected = _selection.keys.contains(lyricSelectionKey(_lines[index]));
    if (_selection.active) {
      return selected
          ? theme.colorScheme.secondary
          : theme.colorScheme.onSurfaceVariant.withValues(alpha: .45);
    }
    final double t = _focus.value.clamp(0.0, 1.0);
    final double emphasis = index == _active
        ? Curves.easeOutCubic.transform(t)
        : index == _previousActive
        ? 1 - Curves.easeOutCubic.transform(t)
        : 0;
    return Color.lerp(
      theme.colorScheme.onSurfaceVariant,
      theme.colorScheme.onSurface,
      emphasis,
    )!;
  }

  Widget _interactive(
    int index,
    String text,
    TextStyle style,
    Widget child,
  ) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _selection.active
          ? _toggleSelection(index)
          : _seekTo(index),
      onLongPress: () => _beginSelection(index),
      child: child,
    );
  }

  Widget _rowBody(int index, ThemeData theme) {
    final LyricLine line = _lines[index];
    final TextStyle style = _mainStyle(context);
    final TextStyle translationStyle = _translationStyle(context);
    final Widget main = line.words.isNotEmpty
        ? TimedLyricText(
            line: line,
            style: style,
            active: index == _active,
            position: () => _state.precisePosition,
            repaint: _wordTick,
          )
        : Text(
            line.text.isEmpty ? ' ' : line.text,
            textAlign: TextAlign.left,
            textDirection: TextDirection.ltr,
            style: style,
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _interactive(index, line.text, style, main),
          if (line.translation?.trim().isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: 5),
            _interactive(
              index,
              line.translation!,
              translationStyle,
              Text(
                line.translation!,
                textAlign: TextAlign.left,
                textDirection: TextDirection.ltr,
                style: translationStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(int index, ThemeData theme) {
    final double sigma = _sigmaFor(index);
    return SizedBox(
      key: ValueKey<String>('lyric-line-${_state.current?.id}-$index'),
      height: _heights[index],
      child: Transform.scale(
        scale: _scaleFor(index),
        alignment: Alignment.centerLeft,
        child: ImageFiltered(
          key: ValueKey<String>('lyric-blur-$index'),
          enabled: sigma > .02,
          imageFilter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: ColorFiltered(
            key: ValueKey<String>('lyric-color-$index'),
            colorFilter: ColorFilter.mode(
              _toneFor(index, theme),
              BlendMode.srcIn,
            ),
            child: RepaintBoundary(child: _rowBody(index, theme)),
          ),
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
          : 5 +
                _measureText(
                  translated,
                  translation,
                  textWidth,
                  scaler,
                );
      final double height = math.max(52, mainHeight + translatedHeight + 20);
      prefix.add(sum);
      heights.add(height);
      sum += height;
    }
    _heights = heights;
    _prefix = prefix;
    _positioned = false;
  }

  double _measureText(
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
  ) {
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: text.isEmpty ? ' ' : text,
        style: style,
      ),
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
        final double centerPad = math.max(
          0,
          constraints.maxHeight * .35 - _heights.first / 2,
        );
        final double averageHeight =
            _heights.fold<double>(0, (double sum, double value) => sum + value) /
                _heights.length;
        if (_active >= _lines.length) _active = _lines.length - 1;
        if (!_positioned) {
          _positioned = true;
          _scheduleCenter(animate: false);
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
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    onPointerSignal: _onPointerSignal,
                    child: AnimatedBuilder(
                      animation: Listenable.merge(<Listenable>[
                        _focus,
                        _blurGate,
                      ]),
                      builder: (BuildContext context, Widget? _) {
                        Widget list = ListView.builder(
                          controller: _scroll,
                          physics: const ClampingScrollPhysics(
                            parent: AlwaysScrollableScrollPhysics(),
                          ),
                          padding: EdgeInsets.only(
                            top: centerPad,
                            bottom: constraints.maxHeight,
                          ),
                          scrollCacheExtent: ScrollCacheExtent.pixels(
                            averageHeight * 2,
                          ),
                          itemCount: _lines.length,
                          itemBuilder: (BuildContext context, int index) =>
                              _row(index, theme),
                        );
                        if (_blurEnabled) {
                          list = LyricEdgeFade(
                            verticalExtent: math.min(
                              constraints.maxHeight * .18,
                              64,
                            ),
                            child: list,
                          );
                        }
                        return list;
                      },
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
                      transitionBuilder: (
                        Widget child,
                        Animation<double> animation,
                      ) => FadeTransition(
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
