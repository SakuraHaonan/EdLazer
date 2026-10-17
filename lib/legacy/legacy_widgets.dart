import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';

/// `mm:ss` for transport labels.
String legacyDuration(Duration value) {
  final int seconds = value.inSeconds.clamp(0, 359999);
  final int minutes = seconds ~/ 60;
  final int rest = seconds % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// Rounded album artwork with the legacy shell's flat placeholder.
class LegacyCover extends StatelessWidget {
  const LegacyCover({
    super.key,
    this.url,
    this.size,
    this.radius = 12,
    this.iconSize = 20,
  });

  final String? url;
  final double? size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String? resolved = enlargedArtworkUrl(url);
    final Widget fallback = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: iconSize,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
    final Widget art = resolved == null || resolved.isEmpty
        ? fallback
        : Image(
            image: ArtworkImage(resolved),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (BuildContext context, Object? error, StackTrace? _) =>
                fallback,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: size == null ? art : SizedBox.square(dimension: size, child: art),
    );
  }
}

/// A playlist card: square cover, name, and the "N 首 · note" line.
class LegacyPlaylistCard extends StatefulWidget {
  const LegacyPlaylistCard({
    super.key,
    required this.playlist,
    required this.onTap,
    this.width = 172,
    this.subtitle,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final double width;
  final String? subtitle;

  @override
  State<LegacyPlaylistCard> createState() => _LegacyPlaylistCardState();
}

class _LegacyPlaylistCardState extends State<LegacyPlaylistCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String detail =
        widget.subtitle ??
        <String>[
          if (widget.playlist.trackCount > 0) '${widget.playlist.trackCount} 首',
          if (widget.playlist.description.isNotEmpty) widget.playlist.description,
        ].join(' · ');
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: _hovering ? 1.015 : 1,
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                child: LegacyCover(
                  url: widget.playlist.coverUrl,
                  size: widget.width,
                  radius: 16,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium,
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A track line: ordinal, cover, title/artist, translated title, duration and
/// a hover play button — the legacy track row.
class LegacyTrackRow extends StatefulWidget {
  const LegacyTrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.onTap,
    this.current = false,
    this.playing = false,
  });

  final Track track;
  final int index;
  final VoidCallback onTap;
  final bool current;
  final bool playing;

  @override
  State<LegacyTrackRow> createState() => _LegacyTrackRowState();
}

class _LegacyTrackRowState extends State<LegacyTrackRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color title = widget.current ? scheme.primary : scheme.onSurface;
    final String? secondary = widget.track.translatedTitle?.trim();
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        color: _hovering
            ? scheme.onSurface.withValues(alpha: 0.05)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: widget.onTap,
          child: SizedBox(
            height: 58,
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Center(
                    child: widget.current
                        ? Icon(
                            widget.playing
                                ? Icons.equalizer_rounded
                                : Icons.pause_rounded,
                            size: 16,
                            color: scheme.primary,
                          )
                        : Text(
                            '${widget.index + 1}',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                  ),
                ),
                LegacyCover(
                  url: widget.track.coverUrl,
                  size: 42,
                  radius: 8,
                  iconSize: 16,
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 5,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: title,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (secondary != null && secondary.isNotEmpty)
                  Expanded(
                    flex: 4,
                    child: Text(
                      secondary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  const Spacer(flex: 4),
                SizedBox(
                  width: 52,
                  child: Text(
                    legacyDuration(widget.track.duration),
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: AnimatedOpacity(
                    opacity: _hovering || widget.current ? 1 : 0,
                    duration: const Duration(milliseconds: 140),
                    child: IconButton(
                      tooltip: widget.current && widget.playing ? '暂停' : '播放',
                      iconSize: 20,
                      onPressed: widget.onTap,
                      icon: Icon(
                        widget.current && widget.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: widget.current ? scheme.primary : scheme.onSurface,
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
  }
}

/// Section heading with an optional muted subtitle and trailing action.
class LegacySectionHeader extends StatelessWidget {
  const LegacySectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineMedium,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

/// Rail entry: rounded pill, icon plus label, filled while selected.
class LegacyRailItem extends StatefulWidget {
  const LegacyRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<LegacyRailItem> createState() => _LegacyRailItemState();
}

class _LegacyRailItemState extends State<LegacyRailItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color foreground = widget.selected
        ? scheme.onSecondaryContainer
        : _hovering
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: widget.selected
                  ? scheme.secondaryContainer
                  : _hovering
                  ? scheme.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 20, color: foreground),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: foreground,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty or loading state inside the legacy pages.
class LegacyNotice extends StatelessWidget {
  const LegacyNotice({
    super.key,
    required this.message,
    this.action,
    this.icon = Icons.music_note_rounded,
  });

  final String message;
  final Widget? action;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// Shuffle, previous, play/pause, next and repeat — the legacy transport row.
class LegacyTransportControls extends StatelessWidget {
  const LegacyTransportControls({
    super.key,
    required this.state,
    this.large = false,
  });

  final AppState state;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final IconData repeatIcon = switch (state.repeat) {
      LoopMode.off => Icons.repeat_rounded,
      LoopMode.all => Icons.repeat_on_rounded,
      LoopMode.one => Icons.repeat_one_on_rounded,
    };
    final double button = large ? 30 : 24;
    final double accent = large ? 56 : 42;
    final Color muted = scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '随机播放',
          onPressed: state.toggleShuffle,
          icon: Icon(
            Icons.shuffle_rounded,
            size: button - 2,
            color: state.shuffle ? scheme.primary : muted,
          ),
        ),
        IconButton(
          tooltip: '上一首',
          onPressed: state.previous,
          icon: Icon(Icons.skip_previous_rounded, size: button),
        ),
        const SizedBox(width: 4),
        Material(
          color: scheme.primary,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: state.togglePlay,
            child: SizedBox.square(
              dimension: accent,
              child: Icon(
                state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: scheme.onPrimary,
                size: large ? 30 : 26,
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: '下一首',
          onPressed: state.next,
          icon: Icon(Icons.skip_next_rounded, size: button),
        ),
        IconButton(
          tooltip: '循环模式',
          onPressed: state.cycleRepeat,
          icon: Icon(
            repeatIcon,
            size: button - 2,
            color: state.repeat == LoopMode.off ? muted : scheme.primary,
          ),
        ),
      ],
    );
  }
}

/// Elapsed/Slider/total, driven by the 100 ms tick lane and draggable.
class LegacyProgressBar extends StatefulWidget {
  const LegacyProgressBar({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyProgressBar> createState() => _LegacyProgressBarState();
}

class _LegacyProgressBarState extends State<LegacyProgressBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return AnimatedBuilder(
      animation: widget.state.all,
      builder: (BuildContext context, _) {
        final Track? track = widget.state.current;
        final double duration = (track?.duration.inMilliseconds ?? 0).toDouble();
        final double position = widget.state.precisePosition.inMilliseconds
            .toDouble();
        final double fraction = _drag ??
            (duration > 0 ? (position / duration).clamp(0.0, 1.0) : 0.0);
        final Duration shown = Duration(
          milliseconds: ((_drag ?? (duration > 0 ? position / duration : 0.0)) *
                  duration)
              .round(),
        );
        return Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(legacyDuration(shown), style: label),
            ),
            Expanded(
              child: Slider(
                value: fraction,
                onChanged: duration > 0
                    ? (double value) => setState(() => _drag = value)
                    : null,
                onChangeEnd: duration > 0
                    ? (double value) {
                        widget.state.seek(value);
                        setState(() => _drag = null);
                      }
                    : null,
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                legacyDuration(track?.duration ?? Duration.zero),
                textAlign: TextAlign.right,
                style: label,
              ),
            ),
          ],
        );
      },
    );
  }
}
