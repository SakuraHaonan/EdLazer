// SPDX-License-Identifier: AGPL-3.0-or-later
// Adapted lyric animation; reference: README.md. License: licenses/lyric_animation/AGPL-3.0.txt.
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../animation/lyric_spring.dart';
import '../data/lyrics.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../theme/design_tokens.dart';
import 'lyric_selection_sheet.dart';
import 'timed_lyric_text.dart';

/// children stay cached while the ticker only updates their transforms.
class LyricViewport extends StatefulWidget {
  const LyricViewport({
    super.key,
    required this.state,
    this.onSelectionChanged,
  });
  final AppState state;
  final ValueChanged<bool>? onSelectionChanged;
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
  List<LyricLine> _lines = const [];
  bool _hasWordTimings = false;
  List<LyricSpring> _ys = [];
  List<LyricSpring> _scales = [];
  List<double> _heights = [];
  List<double> _prefix = [];
  List<Widget> _rows = [];
  Size _size = Size.zero;
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
  }

  int _activeAt(Duration position) {
    var active = -1;
    for (var i = 0; i < widget.state.lyrics.length; i++) {
      if (widget.state.lyrics[i].time > position) break;
      active = i;
    }
    return active;
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
    if (changed) {
      _resume?.cancel();
      _manual = false;
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
  }

  void _updateBlur() {
    final target = widget.state.lyricBlurEnabled && !_manual ? 1.0 : 0.0;
    if (_blurTarget != target) {
      _blurTarget = target;
      _blur.animateTo(target, curve: Curves.easeOutCubic);
    }
  }

  void _start() {
    if (!_ticker.isActive) {
      _lastFrame = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _lastFrame).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastFrame = elapsed;
    if (_hasWordTimings && widget.state.playing) {
      final active = _activeAt(widget.state.precisePosition);
      if (active != _active) {
        setState(() {
          _active = active;
          _rows = [];
          _targets();
          _scaleTargets();
        });
      }
    }
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
      _scales[i].setTarget(i == _active || !widget.state.playing ? 100 : 97);
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

  TextStyle get _originalStyle => AppText.bodySm.copyWith(
    fontSize: 22,
    height: 1.5,
    fontWeight: FontWeight.w600,
  );
  TextStyle get _translationStyle => AppText.bodySm.copyWith(
    fontSize: 16,
    height: 1.45,
    color: AppColors.cloudDark,
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
          _measureText(line.text, _originalStyle, size.width, scaler) +
              (line.translation == null
                  ? 0
                  : 5 +
                        _measureText(
                          line.translation!,
                          _translationStyle,
                          size.width,
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
      _rows = [];
    }
    if (replaced) {
      _ys = [
        for (var i = 0; i < _lines.length; i++) LyricSpring(size.height * 2),
      ];
      _scales = [
        for (var i = 0; i < _lines.length; i++)
          LyricSpring(
            100,
            params: const LyricSpringParams(
              mass: 2,
              damping: 25,
              stiffness: 100,
            ),
          ),
      ];
      _manual = false;
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
    _resume = Timer(
      Duration(milliseconds: (widget.state.lyricResumeSeconds * 1000).round()),
      () {
        if (!mounted || _dragging) return;
        _manual = false;
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
      if (_velocity.sign != event.scrollDelta.dy.sign) _velocity = 0;
      _velocity += ScrollMotion.wheelVelocity(event.scrollDelta.dy);
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

  Future<void> _selectLyrics(int index) async {
    _beginManual();
    _resume?.cancel();
    widget.onSelectionChanged?.call(true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) =>
            LyricSelectionSheet(lines: List.of(_lines), initialIndex: index),
      );
    } finally {
      if (mounted) {
        widget.onSelectionChanged?.call(false);
        _scheduleResume();
      }
    }
  }

  Widget _row(int index) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => _seek(index),
    onLongPress: () => _selectLyrics(index),
    child: SizedBox(
      width: _size.width,
      height: _heights[index],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_lines[index].words.isNotEmpty)
            TimedLyricText(
              line: _lines[index],
              style: _originalStyle.copyWith(
                color: index == _active
                    ? AppColors.slateDark
                    : AppColors.cloudDark,
                fontWeight: index == _active
                    ? FontWeight.w600
                    : FontWeight.w400,
              ),
              active: index == _active,
              position: () => widget.state.precisePosition,
              repaint: _frames,
            )
          else
            Text(
              _lines[index].text.isEmpty ? ' ' : _lines[index].text,
              textAlign: TextAlign.left,
              textDirection: TextDirection.ltr,
              style: _originalStyle.copyWith(
                fontWeight: index == _active
                    ? FontWeight.w600
                    : FontWeight.w400,
                color: index == _active
                    ? AppColors.slateDark
                    : AppColors.cloudDark,
              ),
            ),
          if (_lines[index].translation != null) ...[
            const SizedBox(height: 5),
            Text(
              _lines[index].translation!,
              textAlign: TextAlign.left,
              textDirection: TextDirection.ltr,
              style: _translationStyle,
            ),
          ],
        ],
      ),
    ),
  );
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
              style: AppText.captionMuted,
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
        return Listener(
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
              _dragging = true;
              _beginManual();
            },
            onVerticalDragUpdate: (event) =>
                _setOffset(_offset - event.delta.dy),
            onVerticalDragEnd: (event) {
              _dragging = false;
              _velocity = -event.velocity.pixelsPerSecond.dy;
              _start();
              _scheduleResume();
            },
            onVerticalDragCancel: () {
              _dragging = false;
              _scheduleResume();
            },
            child: ClipRect(
              child: AnimatedBuilder(
                animation: Listenable.merge([_frames, _blur]),
                builder: (context, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    for (var i = 0; i < _lines.length; i++)
                      if (_ys[i].value + _heights[i] >= -80 &&
                          _ys[i].value <= _size.height + 80)
                        Positioned(
                          key: ValueKey(
                            'lyric-line-${widget.state.current?.id}-$i',
                          ),
                          top: 0,
                          left: 0,
                          width: _size.width,
                          height: _heights[i],
                          child: Transform.translate(
                            offset: Offset(0, _ys[i].value),
                            child: Transform.scale(
                              scale: _scales[i].value / 100,
                              alignment: Alignment.centerLeft,
                              child: ImageFiltered(
                                key: ValueKey('lyric-blur-$i'),
                                enabled: _blur.value > 0 && i != _active,
                                imageFilter: ui.ImageFilter.blur(
                                  sigmaX:
                                      math.min(
                                        5.0,
                                        1 +
                                            (i -
                                                        _active.clamp(
                                                          0,
                                                          _lines.length - 1,
                                                        ))
                                                    .abs() *
                                                0.8,
                                      ) *
                                      _blur.value,
                                  sigmaY:
                                      math.min(
                                        5.0,
                                        1 +
                                            (i -
                                                        _active.clamp(
                                                          0,
                                                          _lines.length - 1,
                                                        ))
                                                    .abs() *
                                                0.8,
                                      ) *
                                      _blur.value,
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
        );
      },
    );
  }

  @override
  void dispose() {
    _resume?.cancel();
    widget.state.all.removeListener(_onLane);
    _ticker.dispose();
    _blur.dispose();
    _frames.dispose();
    super.dispose();
  }
}
