import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme/apple_design.dart';
import '../widgets/interaction_feedback.dart';
import '../utils/artwork.dart';
import '../widgets/apple_ui.dart';
import '../widgets/artwork_image.dart';

/// `mm:ss` for transport labels.
String legacyDuration(Duration value) {
  final int seconds = value.inSeconds.clamp(0, 359999);
  final int minutes = seconds ~/ 60;
  final int rest = seconds % 60;
  return '$minutes:${rest.toString().padLeft(2, '0')}';
}

/// The display names of a track's credited artists, falling back to the
/// denormalised artist line.
String legacyArtistNames(Track track) {
  final List<String> names = <String>[
    for (final ArtistRef artist in track.artists)
      if (artist.id > 0 && artist.name.trim().isNotEmpty) artist.name.trim(),
  ];
  return names.isEmpty ? track.artist : names.join(' / ');
}

/// Rounded album artwork with an Apple-like neutral placeholder.
class LegacyCover extends StatelessWidget {
  const LegacyCover({
    super.key,
    this.url,
    this.size,
    this.radius = 8,
    this.iconSize = 20,
  });

  final String? url;
  final double? size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String? resolved = artworkUrlForSize(
      url,
      logicalEdge: size ?? 1024,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final Widget fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            apple.tertiaryFill,
            apple.secondaryFill,
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: iconSize,
          color: apple.tertiaryLabel,
        ),
      ),
    );
    final Widget art = resolved == null || resolved.isEmpty
        ? fallback
        : Image(
            image: ArtworkImage(resolved),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder:
                (BuildContext context, Object? error, StackTrace? _) =>
                    fallback,
          );
    final Widget clipped = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: size == null ? art : SizedBox.square(dimension: size, child: art),
    );
    // A whisper of a border keeps white cover art from dissolving into the
    // light grouped background, matching the Hairline Apple applies to media.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: apple.separator.withValues(alpha: .35), width: .5),
      ),
      child: clipped,
    );
  }
}

/// A playlist card in the Apple Music browse/library style: artwork, title and
/// a quiet metadata line. On pointer platforms the cover raises a play badge.
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String detail =
        widget.subtitle ??
        <String>[
          if (widget.playlist.trackCount > 0)
            '${widget.playlist.trackCount} 首',
          if (widget.playlist.description.isNotEmpty)
            widget.playlist.description,
        ].join(' · ');
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: widget.width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              AnimatedScale(
                scale: _hovering ? 1.018 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Stack(
                  children: <Widget>[
                    RepaintBoundary(
                      child: LegacyCover(
                        url: widget.playlist.coverUrl,
                        size: widget.width,
                        radius: 12,
                      ),
                    ),
                    if (_hovering)
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: AnimatedOpacity(
                          opacity: 1,
                          duration: const Duration(milliseconds: 140),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .72),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(alpha: .18),
                              ),
                            ),
                            child: const Icon(
                              Icons.play_arrow_rounded,
                              size: 21,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: apple.label,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (detail.isNotEmpty) ...<Widget>[
                const SizedBox(height: 1),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: apple.secondaryLabel,
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

/// A track line in the Apple Music list rhythm: artwork, title/translation,
/// artist, optional album and duration. Rows respond to hover without a
/// Material ripple, preserving the calm Apple list feel.
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool wide = MediaQuery.sizeOf(context).width >= 940;
    final String? translated = widget.track.translatedTitle?.trim();
    final Color titleColor = widget.current ? apple.accent : apple.label;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: feedbackAction(context, widget.onTap),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: widget.current
                ? apple.accentSoft
                : _hovering
                ? apple.fill
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 28,
                child: widget.current
                    ? Icon(
                        widget.playing
                            ? Icons.graphic_eq_rounded
                            : Icons.pause_rounded,
                        size: 16,
                        color: apple.accent,
                      )
                    : Text(
                        '${widget.index + 1}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _hovering ? apple.secondaryLabel : apple.tertiaryLabel,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              LegacyCover(
                url: widget.track.coverUrl,
                size: 44,
                radius: 6,
                iconSize: 16,
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 12,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: titleColor,
                        fontWeight: widget.current ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (translated != null && translated.isNotEmpty)
                      Text(
                        translated,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                    Text(
                      widget.track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: apple.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
              if (wide)
                Expanded(
                  flex: 7,
                  child: Text(
                    widget.track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ),
              if (wide || _hovering)
                SizedBox(
                  width: 46,
                  child: Text(
                    legacyDuration(widget.track.duration),
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    color: apple.label,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.35,
                  ),
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: apple.secondaryLabel,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

/// Sidebar entry: icon and label, with the selected row taking the accent.
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final Color labelColor = widget.selected
        ? apple.label
        : _hovering
        ? apple.label
        : apple.secondaryLabel;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? apple.fill
                : _hovering
                ? apple.tertiaryFill
                : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                widget.icon,
                size: 18,
                color: widget.selected ? apple.accent : labelColor,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: labelColor,
                    fontWeight: widget.selected
                        ? FontWeight.w600
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

/// Empty or loading state inside the Apple pages.
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
    return AppleEmptyState(message: message, icon: icon, action: action);
  }
}
