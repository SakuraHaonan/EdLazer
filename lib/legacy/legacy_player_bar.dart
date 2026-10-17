import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'legacy_widgets.dart';

/// The legacy transport bar, ported from `PlayerBar` in
/// `DesktopPlayerApp.kt`:
///
/// ```
/// Surface(height = 84, surface @ 0.96 × uiAlpha, 1 dp outlineVariant border)
///   Row(padding 20)
///     Row(width 250)        now-playing tile (cover 50, title, translation, artist)
///     Column(weight 1)      transport row + thin seek row
///     Row(width 168, end)   volume, queue, now playing
/// ```
class LegacyPlayerBar extends StatelessWidget {
  const LegacyPlayerBar({
    super.key,
    required this.state,
    this.compact = false,
    required this.onOpen,
  });

  final AppState state;

  /// Phone presentation: cover, title and three buttons, 64 dp tall.
  final bool compact;

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: state.all,
      builder: (BuildContext context, _) {
        final Track? track = state.current;
        final double uiAlpha =
            state.legacyBackground == LegacyBackgroundMode.off
            ? 1
            : state.legacyUiAlpha;
        final Color barColor = scheme.surface.withValues(alpha: 0.96 * uiAlpha);
        final BorderSide edge = BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.7),
        );
        if (compact) {
          return Container(
            height: 64,
            decoration: BoxDecoration(
              color: barColor,
              border: Border(top: edge, left: edge, right: edge),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: _NowPlayingTile(
                    track: track,
                    onTap: onOpen,
                    artworkSize: 44,
                  ),
                ),
                _CompactIcon(
                  icon: state.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  tooltip: state.playing ? '暂停' : '播放',
                  iconSize: 26,
                  onPressed: track == null ? null : state.togglePlay,
                ),
                _CompactIcon(
                  icon: Icons.skip_next_rounded,
                  tooltip: '下一首',
                  iconSize: 26,
                  onPressed: track == null ? null : state.next,
                ),
                _CompactIcon(
                  icon: Icons.queue_music_rounded,
                  tooltip: '播放队列',
                  onPressed: () => showLegacyQueueSheet(context, state),
                ),
              ],
            ),
          );
        }
        return Container(
          height: 84,
          decoration: BoxDecoration(
            color: barColor,
            border: Border(top: edge, left: edge, right: edge),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              SizedBox(
                width: 250,
                child: _NowPlayingTile(
                  track: track,
                  onTap: onOpen,
                  artworkSize: 50,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _CompactIcon(
                            icon: state.currentLiked
                                ? Icons.favorite_rounded
                                : Icons.favorite_border_rounded,
                            tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
                            selected: state.currentLiked,
                            onPressed: track == null
                                ? null
                                : () => unawaited(state.toggleLikeCurrent()),
                          ),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: Icons.skip_previous_rounded,
                            tooltip: '上一首',
                            onPressed: track == null ? null : state.previous,
                          ),
                          const SizedBox(width: 3),
                          _PlayButton(state: state),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一首',
                            onPressed: track == null ? null : state.next,
                          ),
                          const SizedBox(width: 3),
                          _CompactIcon(
                            icon: _playModeIcon(state),
                            tooltip: _playModeLabel(state),
                            selected: state.shuffle || state.repeat != LoopMode.off,
                            onPressed: state.cyclePlayMode,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      _SeekRow(state: state),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 168,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _VolumeButton(state: state),
                    const SizedBox(width: 2),
                    _CompactIcon(
                      icon: Icons.queue_music_rounded,
                      tooltip: '播放队列',
                      onPressed: () => showLegacyQueueSheet(context, state),
                    ),
                    const SizedBox(width: 2),
                    _CompactIcon(
                      icon: Icons.lyrics_outlined,
                      tooltip: '歌词',
                      onPressed: onOpen,
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

IconData _playModeIcon(AppState state) {
  if (state.shuffle) return Icons.shuffle_rounded;
  return switch (state.repeat) {
    LoopMode.off => Icons.repeat_rounded,
    LoopMode.all => Icons.repeat_on_rounded,
    LoopMode.one => Icons.repeat_one_on_rounded,
  };
}

String _playModeLabel(AppState state) {
  if (state.shuffle) return '随机播放';
  return switch (state.repeat) {
    LoopMode.off => '顺序播放',
    LoopMode.all => '列表循环',
    LoopMode.one => '单曲循环',
  };
}

/// The clickable now-playing tile: hover washes the surface, click opens the
/// lyrics page.
class _NowPlayingTile extends StatefulWidget {
  const _NowPlayingTile({
    required this.track,
    required this.onTap,
    required this.artworkSize,
  });

  final Track? track;
  final VoidCallback onTap;
  final double artworkSize;

  @override
  State<_NowPlayingTile> createState() => _NowPlayingTileState();
}

class _NowPlayingTileState extends State<_NowPlayingTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Track? track = widget.track;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: ColoredBox(
            color: _hovering
                ? scheme.surfaceContainerHighest.withValues(alpha: 0.55)
                : Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                children: [
                  LegacyCover(
                    url: track?.coverUrl,
                    size: widget.artworkSize,
                    radius: 12,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          track?.title ?? '未选择曲目',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (track?.translatedTitle?.trim().isNotEmpty ?? false)
                          Text(
                            track!.translatedTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        Text(
                          track?.artist ?? 'Lazer',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `CompactIconButton`: a 30 dp hit target with an 18 dp icon.
class _CompactIcon extends StatelessWidget {
  const _CompactIcon({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.iconSize = 18,
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
      dimension: 30,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
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

/// The 38 dp primary play/pause circle with its 21 dp glyph.
class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 38,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 38, height: 38),
        iconSize: 21,
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
          size: 21,
        ),
      ),
    );
  }
}

/// Elapsed time, thin seek bar, total time — the second row of the centre.
class _SeekRow extends StatefulWidget {
  const _SeekRow({required this.state});

  final AppState state;

  @override
  State<_SeekRow> createState() => _SeekRowState();
}

class _SeekRowState extends State<_SeekRow> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    final Track? track = widget.state.current;
    final double duration = (track?.duration.inMilliseconds ?? 0).toDouble();
    final double position = widget.state.precisePosition.inMilliseconds
        .toDouble();
    final double fraction = _drag ??
        (duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0);
    final Duration elapsed = Duration(
      milliseconds: (fraction * duration).round(),
    );
    return Row(
      children: [
        Text(legacyDuration(elapsed), style: label),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: LegacyThinSeekBar(
              progress: fraction,
              onSeek: duration <= 0
                  ? null
                  : (double value) {
                      setState(() => _drag = value);
                      widget.state.seek(value);
                    },
              onSeekFinished: duration <= 0
                  ? null
                  : () => setState(() => _drag = null),
            ),
          ),
        ),
        Text(legacyDuration(track?.duration ?? Duration.zero), style: label),
      ],
    );
  }
}

/// `ThinSeekBar`: a 14 dp hit strip over a 3 dp rounded track with a 10 dp
/// thumb.
class LegacyThinSeekBar extends StatefulWidget {
  const LegacyThinSeekBar({
    super.key,
    required this.progress,
    this.onSeek,
    this.onSeekFinished,
  });

  final double progress;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onSeekFinished;

  @override
  State<LegacyThinSeekBar> createState() => _LegacyThinSeekBarState();
}

class _LegacyThinSeekBarState extends State<LegacyThinSeekBar> {
  static const double _height = 14;
  double? _drag;
  bool _dragging = false;

  void _seekTo(double dx, double width) {
    if (widget.onSeek == null || width <= 0) return;
    final double fraction = (dx / width).clamp(0.0, 1.0);
    setState(() => _drag = fraction);
    widget.onSeek!(fraction);
  }

  void _finish() {
    if (!_dragging) return;
    _dragging = false;
    setState(() => _drag = null);
    widget.onSeekFinished?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double fraction = (_drag ?? widget.progress).clamp(0.0, 1.0);
    return SizedBox(
      height: _height,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double width = constraints.maxWidth;
          final double thumbTravel = math.max(0.0, width - 10);
          final Color track = scheme.surfaceContainerHighest.withValues(
            alpha: 0.95,
          );
          return MouseRegion(
            cursor: widget.onSeek == null
                ? SystemMouseCursors.basic
                : SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: widget.onSeek == null
                  ? null
                  : (TapDownDetails details) =>
                        _seekTo(details.localPosition.dx, width),
              onHorizontalDragStart: widget.onSeek == null
                  ? null
                  : (DragStartDetails details) {
                      _dragging = true;
                      _seekTo(details.localPosition.dx, width);
                    },
              onHorizontalDragUpdate: widget.onSeek == null
                  ? null
                  : (DragUpdateDetails details) =>
                        _seekTo(details.localPosition.dx, width),
              onHorizontalDragEnd: widget.onSeek == null
                  ? null
                  : (DragEndDetails details) => _finish(),
              onHorizontalDragCancel: widget.onSeek == null ? null : _finish,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: (_height - 3) / 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: track,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const SizedBox(height: 3),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: (_height - 3) / 2,
                    width: width * fraction,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const SizedBox(height: 3),
                    ),
                  ),
                  Positioned(
                    left: thumbTravel * fraction,
                    top: (_height - 10) / 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox.square(dimension: 10),
                    ),
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

/// `VolumePanelControl`: hovering the speaker opens a 196 dp panel with the
/// volume percentage and its own thin bar.
class _VolumeButton extends StatefulWidget {
  const _VolumeButton({required this.state});

  final AppState state;

  @override
  State<_VolumeButton> createState() => _VolumeButtonState();
}

class _VolumeButtonState extends State<_VolumeButton> {
  final OverlayPortalController _portal = OverlayPortalController();
  final LayerLink _link = LayerLink();
  Timer? _hide;
  bool _iconHovered = false;
  bool _panelHovered = false;

  void _sync() {
    _hide?.cancel();
    if (_iconHovered || _panelHovered) {
      if (!_portal.isShowing) _portal.show();
      return;
    }
    _hide = Timer(const Duration(milliseconds: 160), () {
      if (!_iconHovered && !_panelHovered && _portal.isShowing) {
        _portal.hide();
      }
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double volume = widget.state.volume.clamp(0.0, 1.0);
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (BuildContext context) => CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.topCenter,
        followerAnchor: Alignment.bottomCenter,
        offset: const Offset(0, -12),
        child: MouseRegion(
            onEnter: (_) {
              _panelHovered = true;
              _sync();
            },
            onExit: (_) {
              _panelHovered = false;
              _sync();
            },
            child: Container(
              width: 196,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: scheme.surface.withValues(alpha: 0.98),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.85),
                ),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '音量 ${(volume * 100).round()}%',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  LegacyThinSeekBar(
                    progress: volume,
                    onSeek: (double value) =>
                        unawaited(widget.state.setVolume(value)),
                  ),
                ],
              ),
            ),
          ),
        ),
      child: CompositedTransformTarget(
        link: _link,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            _iconHovered = true;
            _sync();
          },
          onExit: (_) {
            _iconHovered = false;
            _sync();
          },
          child: _CompactIcon(
            icon: volume <= 0.001
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            tooltip: '音量',
            selected: _portal.isShowing,
            onPressed: () => unawaited(widget.state.toggleMute()),
          ),
        ),
      ),
    );
  }
}

/// The queue panel, restyled as the legacy floating card.
Future<void> showLegacyQueueSheet(BuildContext context, AppState state) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (BuildContext context) => _LegacyQueuePanel(state: state),
  );
}

class _LegacyQueuePanel extends StatelessWidget {
  const _LegacyQueuePanel({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 18, 16, 8),
              child: Row(
                children: [
                  Text(
                    '播放队列 · ${state.queue.length} 首',
                    style: theme.textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
            ),
            Expanded(
              child: state.queue.isEmpty
                  ? const LegacyNotice(message: '队列还是空的。')
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: state.queue.length,
                      itemBuilder: (BuildContext context, int index) {
                        final Track track = state.queue[index];
                        return LegacyTrackRow(
                          track: track,
                          index: index,
                          current: state.queueIndex == index,
                          playing: state.playing,
                          onTap: () => state.playTrackAt(index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
