import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../screens/catalog_detail_page.dart';
import '../state/app_state.dart';
import '../state/detail_requests.dart';
import '../theme/app_palette.dart';
import 'interaction_feedback.dart';

Future<void> openArtists(
  BuildContext context,
  AppState state,
  List<ArtistRef> artists,
) async {
  final available = {
    for (final artist in artists)
      if (artist.id > 0 && artist.name.trim().isNotEmpty) artist.id: artist,
  }.values.toList();
  if (available.isEmpty) return;
  final selected = available.length == 1
      ? available.single
      : await showDialog<ArtistRef>(
          context: context,
          builder: (context) => AlertDialog(
            title: const TrText('选择歌手'),
            content: SizedBox(
              width: 360,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final artist in available)
                      ListTile(
                        title: Text(artist.name),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: feedbackAction(
                          context,
                          () => Navigator.pop(context, artist),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
  if (selected == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CatalogDetailPage.artist(state: state, artist: selected),
    ),
  );
}

Future<void> openAlbumDetails(
  BuildContext context,
  AppState state,
  Album album,
) async {
  if ((int.tryParse(album.id) ?? 0) <= 0) return;
  // The shell owns the detail slot and slides the player away, so an album tap
  // loads on the right of the main page instead of taking over the window.
  Navigator.of(context).popUntil((Route<void> route) => route.isFirst);
  albumDetailRequest.value = album;
}

class CatalogTextLink extends StatelessWidget {
  const CatalogTextLink({
    super.key,
    required this.text,
    required this.onTap,
    this.style,
    this.maxLines = 1,
  });
  final String text;
  final VoidCallback? onTap;
  final TextStyle? style;
  final int maxLines;
  @override
  Widget build(BuildContext context) {
    final label = Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: style,
    );
    if (onTap == null) return label;
    return Semantics(
      link: true,
      child: Material(
        color: Colors.transparent,
        textStyle: style ?? DefaultTextStyle.of(context).style,
        child: InkWell(
          borderRadius: BorderRadius.zero,
          hoverColor: context.colors.oatWarm.withValues(alpha: .4),
          focusColor: context.colors.clay.withValues(alpha: .18),
          onTap: feedbackAction(context, onTap),
          child: label,
        ),
      ),
    );
  }
}

class ArtistNameLink extends StatelessWidget {
  const ArtistNameLink({
    super.key,
    required this.state,
    required this.artists,
    required this.fallback,
    this.style,
    this.maxLines = 1,
  });
  final AppState state;
  final List<ArtistRef> artists;
  final String fallback;
  final TextStyle? style;
  final int maxLines;
  @override
  Widget build(BuildContext context) => CatalogTextLink(
    text: fallback,
    style: style,
    maxLines: maxLines,
    onTap:
        artists.any((artist) => artist.id > 0 && artist.name.trim().isNotEmpty)
        ? () => unawaited(openArtists(context, state, artists))
        : null,
  );
}

class AlbumNameLink extends StatelessWidget {
  const AlbumNameLink({
    super.key,
    required this.state,
    required this.track,
    this.style,
  });
  final AppState state;
  final Track track;
  final TextStyle? style;
  @override
  Widget build(BuildContext context) => CatalogTextLink(
    text: track.album,
    style: style,
    onTap: track.albumId > 0
        ? () => unawaited(
            openAlbumDetails(
              context,
              state,
              Album(
                id: '${track.albumId}',
                title: track.album,
                artist: track.artist,
                artists: track.artists,
                year: '',
                coverSeed: track.coverSeed,
                coverUrl: track.coverUrl,
                note: '',
              ),
            ),
          )
        : null,
  );
}
