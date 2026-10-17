import 'package:flutter/material.dart';

import '../data/models.dart';
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
    this.width = 148,
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
                style: theme.textTheme.titleSmall,
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
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

/// A track line, laid out like the legacy `TrackRow`: ordinal, cover 44,
/// title / translation / artist stacked, album, duration, play button.
class LegacyTrackRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final String? translated = track.translatedTitle?.trim();
    final Color titleColor = current ? scheme.primary : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: current
            ? scheme.primaryContainer.withValues(alpha: 0.68)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(11),
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text(
                    '${index + 1}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: current ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                LegacyCover(
                  url: track.coverUrl,
                  size: 44,
                  radius: 10,
                  iconSize: 16,
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 12,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: titleColor,
                        ),
                      ),
                      if (translated != null && translated.isNotEmpty)
                        Text(
                          translated,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 8,
                  child: Text(
                    track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    legacyDuration(track.duration),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                SizedBox.square(
                  dimension: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    visualDensity: VisualDensity.compact,
                    tooltip: current && playing ? '暂停' : '播放',
                    onPressed: onTap,
                    icon: Icon(
                      current && playing
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 17,
                      color: scheme.primary,
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
            style: theme.textTheme.headlineSmall,
          ),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
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
    final Color labelColor = widget.selected
        ? scheme.onPrimaryContainer
        : _hovering
        ? scheme.onSurface
        : scheme.onSurfaceVariant;
    final Color iconColor = widget.selected ? scheme.primary : labelColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? scheme.primaryContainer
                : _hovering
                ? scheme.onSurface.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 19, color: iconColor),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: labelColor,
                    fontWeight: widget.selected
                        ? FontWeight.w500
                        : FontWeight.w400,
                  ),
                ),
              ),
            ],
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

