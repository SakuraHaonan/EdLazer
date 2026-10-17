import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../data/lyrics.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'legacy_background.dart';
import 'legacy_player_bar.dart';
import 'legacy_theme.dart';
import 'legacy_widgets.dart';

/// The legacy now-playing page, ported from `DesktopNowPlayingPage` in
/// `DesktopPlayerApp.kt`: album-flow background with a paper veil, the hero
/// artwork and transport card on the left (44%), the lyric sheet on the right
/// (56%).
class LegacyNowPlayingPage extends StatelessWidget {
  const LegacyNowPlayingPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color page = legacyPageBackground(theme.brightness);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) {
          final Track? track = state.current;
          if (track == null) {
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: page),
                const Center(child: LegacyNotice(message: '还没有播放中的曲目。')),
              ],
            );
          }
          final bool backdrop =
              state.legacyBackground != LegacyBackgroundMode.off;
          return Stack(
            fit: StackFit.expand,
            children: [
              LegacyAlbumBackdrop(
                track: track,
                mode: state.legacyBackground,
                uiAlpha: state.legacyUiAlpha,
                pageColor: page,
                veil: backdrop ? page.withValues(alpha: 0.38) : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 18,
                ),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // The legacy canvas sizes the hero from the pane, clamped
                    // so a tall window cannot grow it past 420 dp.
                    final double coverSide = math
                        .min(
                          constraints.maxHeight * 0.38,
                          constraints.maxWidth * 0.24,
                        )
                        .clamp(140.0, 420.0);
                    final Widget closeRow = SizedBox(
                      height: 52,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: '收起',
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    );
                    if (constraints.maxWidth < 860) {
                      // Narrow windows stack the same three blocks instead of
                      // squeezing the 44/56 split past its minimum.
                      return Column(
                        children: [
                          closeRow,
                          Expanded(
                            flex: 5,
                            child: SingleChildScrollView(
                              child: _Hero(
                                track: track,
                                coverSide: coverSide.clamp(140.0, 260.0),
                              ),
                            ),
                          ),
                          _NowPlayingControls(state: state),
                          Expanded(
                            flex: 6,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: LegacyLyricsViewport(state: state),
                            ),
                          ),
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(
                          flex: 44,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Column(
                              children: [
                                closeRow,
                                Expanded(
                                  child: Center(
                                    child: _Hero(
                                      track: track,
                                      coverSide: coverSide,
                                    ),
                                  ),
                                ),
                                _NowPlayingControls(state: state),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 18),
                        Expanded(
                          flex: 56,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: LegacyLyricsViewport(state: state),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Cover with the legacy drop shadow, then title, translated title and artist.
class _Hero extends StatelessWidget {
  const _Hero({required this.track, required this.coverSide});

  final Track track;
  final double coverSide;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.46),
                blurRadius: 26,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: LegacyCover(
            url: track.coverUrl,
            size: coverSide,
            radius: 24,
            iconSize: 40,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        if (track.translatedTitle?.trim().isNotEmpty ?? false)
          Text(
            track.translatedTitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: 2),
        Text(
          track.artist,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The rounded transport card: thin seek bar, elapsed/total, then the five
/// transport controls.
class _NowPlayingControls extends StatefulWidget {
  const _NowPlayingControls({required this.state});

  final AppState state;

  @override
  State<_NowPlayingControls> createState() => _NowPlayingControlsState();
}

class _NowPlayingControlsState extends State<_NowPlayingControls> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedBuilder(
        animation: widget.state.all,
        builder: (BuildContext context, _) {
          final AppState state = widget.state;
          final Track? track = state.current;
          final double duration = (track?.duration.inMilliseconds ?? 0).toDouble();
          final double position = state.precisePosition.inMilliseconds.toDouble();
          final double fraction = _drag ??
              (duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0);
          return Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 600),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.86),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.72),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LegacyThinSeekBar(
                    progress: fraction,
                    onSeek: duration <= 0
                        ? null
                        : (double value) {
                            setState(() => _drag = value);
                            state.seek(value);
                          },
                    onSeekFinished: duration <= 0
                        ? null
                        : () => setState(() => _drag = null),
                  ),
                  Row(
                    children: [
                      Text(
                        legacyDuration(
                          Duration(milliseconds: (fraction * duration).round()),
                        ),
                        style: label,
                      ),
                      const Spacer(),
                      Text(
                        legacyDuration(track?.duration ?? Duration.zero),
                        style: label,
                      ),
                    ],
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _CardIcon(
                        icon: state.currentLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
                        selected: state.currentLiked,
                        onPressed: track == null
                            ? null
                            : () => unawaited(state.toggleLikeCurrent()),
                      ),
                      _CardIcon(
                        icon: Icons.skip_previous_rounded,
                        tooltip: '上一首',
                        iconSize: 27,
                        onPressed: track == null ? null : state.previous,
                      ),
                      _PlayCircle(state: state),
                      _CardIcon(
                        icon: Icons.skip_next_rounded,
                        tooltip: '下一首',
                        iconSize: 27,
                        onPressed: track == null ? null : state.next,
                      ),
                      _CardIcon(
                        icon: _modeIcon(state),
                        tooltip: _modeLabel(state),
                        selected: state.shuffle || state.repeat != LoopMode.off,
                        onPressed: state.cyclePlayMode,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

IconData _modeIcon(AppState state) {
  if (state.shuffle) return Icons.shuffle_rounded;
  return switch (state.repeat) {
    LoopMode.off => Icons.repeat_rounded,
    LoopMode.all => Icons.repeat_on_rounded,
    LoopMode.one => Icons.repeat_one_on_rounded,
  };
}

String _modeLabel(AppState state) {
  if (state.shuffle) return '随机播放';
  return switch (state.repeat) {
    LoopMode.off => '顺序播放',
    LoopMode.all => '列表循环',
    LoopMode.one => '单曲循环',
  };
}

class _CardIcon extends StatelessWidget {
  const _CardIcon({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.iconSize = 24,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        iconSize: iconSize,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          disabledForegroundColor: scheme.onSurfaceVariant.withValues(
            alpha: 0.4,
          ),
        ),
        icon: Icon(icon, size: iconSize),
      ),
    );
  }
}

class _PlayCircle extends StatelessWidget {
  const _PlayCircle({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 52,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 52, height: 52),
        iconSize: 29,
        visualDensity: VisualDensity.compact,
        tooltip: state.playing ? '暂停' : '播放',
        onPressed: state.current == null ? null : state.togglePlay,
        style: IconButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: scheme.primary.withValues(alpha: 0.4),
          disabledForegroundColor: scheme.onPrimary.withValues(alpha: 0.6),
        ),
        icon: Icon(
          state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          size: 29,
        ),
      ),
    );
  }
}

/// The legacy lyric sheet: centered lines that keep the singing line in the
/// middle of the pane, with distance-based blur and fade, and a translation
/// under each line.
class LegacyLyricsViewport extends StatefulWidget {
  const LegacyLyricsViewport({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyLyricsViewport> createState() => _LegacyLyricsViewportState();
}

class _LegacyLyricsViewportState extends State<LegacyLyricsViewport> {
  static const double _gapRatio = 0.10;

  AppState get state => widget.state;

  double _scroll = 0;
  bool _following = true;
  Timer? _resume;
  int _activeIndex = 0;
  int _lineCount = 0;

  /// Measured geometry from the last build; the tick listener reads it.
  List<double> _centers = const <double>[];
  double _maxScroll = 0;
  _LyricGeometry? _cachedGeometry;
  double _cachedWidth = -1;
  double _cachedHeight = -1;
  double _cachedFontSize = -1;
  List<LyricLine>? _cachedLyrics;
  Brightness? _cachedBrightness;

  @override
  void initState() {
    super.initState();
    state.addListener(_onStructural);
    state.ticks.addListener(_onTick);
  }

  @override
  void didUpdateWidget(LegacyLyricsViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStructural);
      oldWidget.state.ticks.removeListener(_onTick);
      widget.state.addListener(_onStructural);
      widget.state.ticks.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    _resume?.cancel();
    state.removeListener(_onStructural);
    state.ticks.removeListener(_onTick);
    super.dispose();
  }

  int _indexAt(Duration position) {
    final List<LyricLine> lines = state.lyrics;
    int index = 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _onStructural() {
    if (!mounted) return;
    setState(() {
      if (_lineCount != state.lyrics.length) {
        _lineCount = state.lyrics.length;
        _activeIndex = _indexAt(state.precisePosition);
        _following = true;
        _scroll = _centers.isEmpty
            ? 0
            : _centers[_activeIndex.clamp(0, _centers.length - 1)];
      }
    });
  }

  void _onTick() {
    if (!mounted || !_following || _centers.isEmpty) return;
    final int index = _indexAt(state.precisePosition);
    if (index == _activeIndex) return;
    final int clamped = index.clamp(0, _centers.length - 1);
    setState(() {
      _activeIndex = clamped;
      _scroll = _centers[clamped];
    });
  }

  void _seekToLine(LyricLine line) {
    final Duration total = state.current?.duration ?? Duration.zero;
    if (total.inMilliseconds <= 0) return;
    state.seek(line.time.inMilliseconds / total.inMilliseconds);
  }

  void _manualScroll(double delta) {
    if (_centers.isEmpty) return;
    _resume?.cancel();
    setState(() {
      _following = false;
      _scroll = (_scroll + delta).clamp(0.0, _maxScroll);
    });
    final int delay = state.lyricResumeSeconds.round().clamp(1, 10);
    _resume = Timer(Duration(seconds: delay), () {
      if (!mounted) return;
      setState(() {
        _following = true;
        _scroll = _centers.isEmpty
            ? 0
            : _centers[_activeIndex.clamp(0, _centers.length - 1)];
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (state.current == null) {
      return const Center(child: Text('还没有播放中的曲目。'));
    }
    if (state.lyricsLoading && state.lyrics.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '正在加载歌词…',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }
    if (state.lyrics.isEmpty) {
      return Center(
        child: Text(
          state.lyricsError ??
              (state.lyricsPureMusic ? '纯音乐，请欣赏' : '这首歌还没有同步歌词。'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final _LyricGeometry geometry = _geometryFor(
          theme,
          constraints.maxWidth,
          constraints.maxHeight,
        );
        _centers = geometry.centers;
        _maxScroll = geometry.maxScroll;
        if (_lineCount != state.lyrics.length) {
          _lineCount = state.lyrics.length;
          _activeIndex = _indexAt(state.precisePosition);
          _scroll = geometry.centers.isEmpty
              ? 0
              : geometry.centers[_activeIndex.clamp(
                  0,
                  geometry.centers.length - 1,
                )];
        }
        final double center = constraints.maxHeight / 2;
        final bool follow = _following;
        return Listener(
          onPointerSignal: (PointerSignalEvent event) {
            if (event is PointerScrollEvent) {
              _manualScroll(event.scrollDelta.dy);
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (DragUpdateDetails details) =>
                _manualScroll(-details.delta.dy),
            child: ClipRect(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _scroll),
                duration: follow
                    ? const Duration(milliseconds: 320)
                    : Duration.zero,
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double scroll, Widget? _) {
                  final List<Widget> rows = <Widget>[];
                  for (int i = 0; i < state.lyrics.length; i++) {
                    final double top =
                        center +
                        geometry.centers[i] -
                        scroll -
                        geometry.heights[i] / 2;
                    if (top > constraints.maxHeight + 40 ||
                        top + geometry.heights[i] < -40) {
                      continue;
                    }
                    rows.add(
                      Positioned(
                        left: 20,
                        right: 20,
                        top: top,
                        child: _LyricRow(
                          line: state.lyrics[i],
                          active: i == _activeIndex,
                          distance: (i - _activeIndex).abs().toDouble(),
                          mainStyle: geometry.mainStyle,
                          translationStyle: geometry.translationStyle,
                          translationGap: geometry.translationGaps[i],
                          narrow: constraints.maxWidth <= 1024,
                          onTap: () => _seekToLine(state.lyrics[i]),
                        ),
                      ),
                    );
                  }
                  return Stack(children: rows);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Re-lays the sheet only when the lyrics, the font size, the theme or the
  /// pane size changes — a volume drag elsewhere must not re-measure 100 lines.
  _LyricGeometry _geometryFor(ThemeData theme, double width, double height) {
    final _LyricGeometry? cached = _cachedGeometry;
    if (cached != null &&
        _cachedWidth == width &&
        _cachedHeight == height &&
        _cachedFontSize == state.legacyLyricFontSize &&
        identical(_cachedLyrics, state.lyrics) &&
        _cachedBrightness == theme.brightness) {
      return cached;
    }
    final _LyricGeometry geometry = _measure(theme, width, height);
    _cachedGeometry = geometry;
    _cachedWidth = width;
    _cachedHeight = height;
    _cachedFontSize = state.legacyLyricFontSize;
    _cachedLyrics = state.lyrics;
    _cachedBrightness = theme.brightness;
    return geometry;
  }

  _LyricGeometry _measure(
    ThemeData theme,
    double width,
    double height,
  ) {
    final TextStyle mainStyle = theme.textTheme.bodyLarge!.copyWith(
      fontWeight: FontWeight.w600,
      fontSize: state.legacyLyricFontSize,
      height: 1.38,
    );
    final double translationFont = (state.legacyLyricFontSize * 0.48).clamp(12.0, 20.0);
    final TextStyle translationStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: translationFont,
      height: 1.36,
      fontWeight: FontWeight.w400,
    );
    final double textWidth = math.max(40.0, (width - 40) / 1.04);
    final double lineHeight = state.legacyLyricFontSize * 1.38;
    final double minRowGap = lineHeight * 0.32;
    final double maxRowGap = lineHeight * 0.95;
    final double minTranslationGap = lineHeight * 0.18;
    final double maxTranslationGap = lineHeight * 0.55;

    final List<double> heights = <double>[];
    final List<double> translationGaps = <double>[];
    for (final LyricLine line in state.lyrics) {
      final TextPainter main = TextPainter(
        text: TextSpan(
          text: line.text.isEmpty ? '…' : line.text,
          style: mainStyle,
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: textWidth);
      double rowHeight = main.height;
      double gap = 0;
      final String? translation = line.translation?.trim();
      if (translation != null && translation.isNotEmpty) {
        final TextPainter sub = TextPainter(
          text: TextSpan(text: translation, style: translationStyle),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        )..layout(maxWidth: textWidth);
        gap = (main.height * 0.18).clamp(minTranslationGap, maxTranslationGap);
        rowHeight += gap + sub.height;
      }
      heights.add(rowHeight);
      translationGaps.add(gap);
    }

    final List<double> centers = List<double>.filled(heights.length, 0);
    for (int i = 1; i < heights.length; i++) {
      final double gap = ((heights[i - 1] + heights[i]) * _gapRatio).clamp(
        minRowGap,
        maxRowGap,
      );
      centers[i] = centers[i - 1] + heights[i - 1] / 2 + gap + heights[i] / 2;
    }
    return _LyricGeometry(
      heights: heights,
      centers: centers,
      translationGaps: translationGaps,
      mainStyle: mainStyle,
      translationStyle: translationStyle,
      maxScroll: centers.isEmpty ? 0 : centers.last,
    );
  }
}

class _LyricGeometry {
  const _LyricGeometry({
    required this.heights,
    required this.centers,
    required this.translationGaps,
    required this.mainStyle,
    required this.translationStyle,
    required this.maxScroll,
  });

  final List<double> heights;
  final List<double> centers;
  final List<double> translationGaps;
  final TextStyle mainStyle;
  final TextStyle translationStyle;
  final double maxScroll;
}

/// One lyric row: the AMLL fade/blur/scale ramp around the singing line.
class _LyricRow extends StatelessWidget {
  const _LyricRow({
    required this.line,
    required this.active,
    required this.distance,
    required this.mainStyle,
    required this.translationStyle,
    required this.translationGap,
    required this.narrow,
    required this.onTap,
  });

  final LyricLine line;
  final bool active;
  final double distance;
  final TextStyle mainStyle;
  final TextStyle translationStyle;
  final double translationGap;
  final bool narrow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double focus = active ? 1 : 0;
    final double ambient = (1 - distance / 4).clamp(0.0, 1.0);
    final double baseAlpha = 0.62 + ambient * 0.18;
    final double alpha = baseAlpha * (1 - focus) + 0.85 * focus;
    final double scale = 0.97 + 0.03 * focus;
    final double blur = math.min(
      9.0,
      (1 + distance) * (narrow ? 0.8 : 1.0) * (1 - focus),
    );
    final Color color = Color.lerp(
      scheme.onSurfaceVariant,
      scheme.onSurface,
      focus,
    )!;
    final String? translation = line.translation?.trim();
    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          line.text.isEmpty ? '…' : line.text,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: mainStyle.copyWith(color: color),
        ),
        if (translation != null && translation.isNotEmpty) ...[
          SizedBox(height: translationGap),
          Text(
            translation,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: translationStyle.copyWith(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.96),
            ),
          ),
        ],
      ],
    );
    if (blur > 0.05) {
      content = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.decal,
        ),
        child: content,
      );
    }
    return Opacity(
      opacity: alpha.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: content,
        ),
      ),
    );
  }
}
