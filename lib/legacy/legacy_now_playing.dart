import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../widgets/lyric_viewport.dart';
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
    final Color page = legacyPageBackgroundOf(theme.colorScheme);
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
                              child: LyricViewport(state: state),
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
                            child: LyricViewport(state: state),
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
