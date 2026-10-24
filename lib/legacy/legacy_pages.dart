import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/catalog_details.dart';
import '../data/models.dart';
import '../l10n/app_language.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/apple_ui.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/motion_artwork.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_login.dart';
import 'legacy_widgets.dart';

/// Apple Music-inspired artist overview that lives inside the shell's content
/// pane. It deliberately keeps the hero compact and lets releases carry the
/// visual weight below it.
class LegacyArtistPage extends StatefulWidget {
  const LegacyArtistPage({
    super.key,
    required this.state,
    required this.artist,
    required this.onOpenAllSongs,
    required this.onOpenAlbums,
    required this.onOpenSingles,
  });

  final AppState state;
  final ArtistRef artist;
  final VoidCallback onOpenAllSongs;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenSingles;

  @override
  State<LegacyArtistPage> createState() => _LegacyArtistPageState();
}

class _LegacyArtistPageState extends State<LegacyArtistPage> {
  ArtistDetails? _details;
  final List<Album> _albums = <Album>[];
  String? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant LegacyArtistPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist.id != widget.artist.id) unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    final int generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _albums.clear();
    });
    try {
      final ArtistDetails details = await widget.state.catalog.artistDetails(
        widget.artist,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _details = details);
      var offset = 0;
      var more = true;
      final List<Album> albums = <Album>[];
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await widget.state.catalog.artistAlbumPage(
          widget.artist.id,
          offset: offset,
          force: force,
        );
        albums.addAll(page.albums.where((album) => ids.add(album.id)));
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _albums.addAll(albums);
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () => _error =
              '\u6b4c\u624b\u8d44\u6599\u52a0\u8f7d\u5931\u8d25\uff0c\u8bf7\u91cd\u8bd5\u3002',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ArtistRef artist = _details?.artist ?? widget.artist;
    final List<Track> popular =
        _details?.tracks.take(9).toList() ?? const <Track>[];
    final List<Album> fullAlbums = _albums
        .where((album) => album.releaseGroup == AlbumReleaseGroup.album)
        .toList();
    final List<Album> singles = _albums
        .where((album) => album.releaseGroup != AlbumReleaseGroup.album)
        .toList();
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 20, inset, 42),
          children: <Widget>[
            _ArtistHero(
              artist: artist,
              songCount: _details?.musicCount ?? 0,
              albumCount: _details?.albumCount ?? 0,
              onPlay: popular.isEmpty
                  ? null
                  : () => widget.state.playQueue(_details!.tracks),
            ),
            if (_loading && _details == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 72),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null && _details == null)
              LegacyNotice(
                message: _error!,
                action: FilledButton(
                  onPressed: () => unawaited(_load(force: true)),
                  child: const Text('\u91cd\u8bd5'),
                ),
              )
            else ...<Widget>[
              const SizedBox(height: 38),
              LegacySectionHeader(
                title: '\u6b4c\u66f2\u6392\u884c',
                subtitle: popular.isEmpty
                    ? null
                    : '\u70ed\u95e8 ${popular.length} \u9996',
                trailing: TextButton.icon(
                  key: const ValueKey<String>('artist-all-songs'),
                  onPressed: widget.onOpenAllSongs,
                  iconAlignment: IconAlignment.end,
                  icon: const Icon(Icons.chevron_right_rounded, size: 18),
                  label: const Text('\u67e5\u770b\u5168\u90e8'),
                ),
              ),
              const SizedBox(height: 10),
              if (popular.isEmpty)
                const LegacyNotice(
                  message: '\u6682\u65e0\u70ed\u95e8\u6b4c\u66f2',
                )
              else
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints box) {
                    final int columns = box.maxWidth >= 920
                        ? 3
                        : box.maxWidth >= 560
                        ? 2
                        : 1;
                    final double width =
                        (box.maxWidth - (columns - 1) * 10) / columns;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: <Widget>[
                        for (int i = 0; i < popular.length; i++)
                          SizedBox(
                            width: width,
                            child: _ArtistTrackCard(
                              track: popular[i],
                              current:
                                  widget.state.current?.id == popular[i].id,
                              onTap: () => widget.state.playQueue(
                                _details!.tracks,
                                startIndex: i,
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              if (fullAlbums.isNotEmpty) ...<Widget>[
                const SizedBox(height: 36),
                LegacySectionHeader(
                  title: '\u4e13\u8f91',
                  subtitle:
                      '${fullAlbums.length} \u5f20\u5168\u957f\u4e13\u8f91',
                  trailing: TextButton.icon(
                    key: const ValueKey<String>('artist-all-albums'),
                    onPressed: widget.onOpenAlbums,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const Text('\u67e5\u770b\u5168\u90e8'),
                  ),
                ),
                const SizedBox(height: 14),
                _ArtistReleaseShelf(state: widget.state, albums: fullAlbums),
              ],
              if (singles.isNotEmpty) ...<Widget>[
                const SizedBox(height: 36),
                LegacySectionHeader(
                  title: '\u5355\u66f2 / EP',
                  subtitle: '${singles.length} \u5f20',
                  trailing: TextButton.icon(
                    key: const ValueKey<String>('artist-all-singles'),
                    onPressed: widget.onOpenSingles,
                    iconAlignment: IconAlignment.end,
                    icon: const Icon(Icons.chevron_right_rounded, size: 18),
                    label: const Text('\u67e5\u770b\u5168\u90e8'),
                  ),
                ),
                const SizedBox(height: 14),
                _ArtistReleaseShelf(state: widget.state, albums: singles),
              ],
              if ((_details?.description ?? '').trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 38),
                const LegacySectionHeader(title: '\u5173\u4e8e'),
                const SizedBox(height: 12),
                Text(
                  _details!.description,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.55,
                    color: AppleSemanticColors.of(context).secondaryLabel,
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ArtistHero extends StatelessWidget {
  const _ArtistHero({
    required this.artist,
    required this.songCount,
    required this.albumCount,
    required this.onPlay,
  });

  final ArtistRef artist;
  final int songCount;
  final int albumCount;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Column(
      children: <Widget>[
        ClipOval(
          child: SizedBox.square(
            dimension: 180,
            child: LegacyCover(url: artist.coverUrl, radius: 0, iconSize: 50),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          artist.name,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.displaySmall?.copyWith(
            color: apple.label,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.1,
          ),
        ),
        if (songCount > 0 || albumCount > 0) ...<Widget>[
          const SizedBox(height: 7),
          Text(
            <String>[
              if (songCount > 0) '$songCount \u9996\u6b4c\u66f2',
              if (albumCount > 0) '$albumCount \u5f20\u53d1\u884c',
            ].join(' \u00b7 '),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: apple.secondaryLabel),
          ),
        ],
        const SizedBox(height: 17),
        FilledButton.icon(
          onPressed: onPlay,
          icon: const Icon(Icons.play_arrow_rounded, size: 23),
          label: const Text('\u64ad\u653e'),
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
          ),
        ),
      ],
    );
  }
}

class _ArtistTrackCard extends StatefulWidget {
  const _ArtistTrackCard({
    required this.track,
    required this.current,
    required this.onTap,
  });
  final Track track;
  final bool current;
  final VoidCallback onTap;

  @override
  State<_ArtistTrackCard> createState() => _ArtistTrackCardState();
}

class _ArtistTrackCardState extends State<_ArtistTrackCard> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: feedbackAction(context, widget.onTap),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            height: 66,
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: widget.current
                  ? apple.accentSoft
                  : _hover
                  ? apple.fill
                  : apple.secondaryGroupedBackground,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: apple.separator, width: .5),
            ),
            child: Row(
              children: <Widget>[
                LegacyCover(url: widget.track.coverUrl, size: 52, radius: 6),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: widget.current ? apple.accent : apple.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        <String>[
                          widget.track.album,
                          if (widget.track.duration > Duration.zero)
                            legacyDuration(widget.track.duration),
                        ].join(' \u00b7 '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: apple.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.more_horiz_rounded, color: apple.tertiaryLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ArtistReleaseShelf extends StatelessWidget {
  const _ArtistReleaseShelf({required this.state, required this.albums});
  final AppState state;
  final List<Album> albums;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 220,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      clipBehavior: Clip.none,
      itemCount: albums.length,
      separatorBuilder: (_, _) => const SizedBox(width: 16),
      itemBuilder: (BuildContext context, int index) {
        final Album album = albums[index];
        return SizedBox(
          width: 160,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: feedbackAction(
              context,
              () => unawaited(openAlbumDetails(context, state, album)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LegacyCover(url: album.coverUrl, size: 160, radius: 9),
                const SizedBox(height: 8),
                Text(
                  album.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  <String>[
                    if (album.year.isNotEmpty) album.year,
                    if (album.releaseType.isNotEmpty) album.releaseType,
                  ].join(' \u00b7 '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppleSemanticColors.of(context).secondaryLabel,
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

class LegacyArtistReleasesPage extends StatefulWidget {
  const LegacyArtistReleasesPage({
    super.key,
    required this.state,
    required this.artist,
    required this.group,
  });

  final AppState state;
  final ArtistRef artist;
  final AlbumReleaseGroup group;

  @override
  State<LegacyArtistReleasesPage> createState() =>
      _LegacyArtistReleasesPageState();
}

class _LegacyArtistReleasesPageState extends State<LegacyArtistReleasesPage> {
  List<Album>? _albums;
  String? _error;

  String get _title => widget.group == AlbumReleaseGroup.album
      ? '\u5168\u90e8\u4e13\u8f91'
      : '\u5168\u90e8\u5355\u66f2 / EP';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _error = null;
      if (force) _albums = null;
    });
    try {
      var offset = 0;
      var more = true;
      final List<Album> releases = <Album>[];
      final Set<String> ids = <String>{};
      while (more) {
        final ArtistAlbumPage page = await widget.state.catalog.artistAlbumPage(
          widget.artist.id,
          offset: offset,
          force: force,
        );
        for (final Album album in page.albums) {
          final bool matches = widget.group == AlbumReleaseGroup.album
              ? album.releaseGroup == AlbumReleaseGroup.album
              : album.releaseGroup != AlbumReleaseGroup.album;
          if (matches && ids.add(album.id)) releases.add(album);
        }
        offset += page.receivedCount;
        more = page.more && page.receivedCount > 0;
      }
      if (mounted) setState(() => _albums = releases);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              '\u53d1\u884c\u4f5c\u54c1\u52a0\u8f7d\u5931\u8d25\uff0c\u8bf7\u91cd\u8bd5\u3002',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Album>? albums = _albums;
    final double inset = _pageInset(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 16),
              sliver: SliverToBoxAdapter(
                child: ApplePageTitle(
                  title: _title,
                  subtitle: albums == null
                      ? widget.artist.name
                      : '${widget.artist.name} \u00b7 ${albums.length} \u5f20',
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: LegacyNotice(
                  message: _error!,
                  action: FilledButton(
                    onPressed: () => unawaited(_load(force: true)),
                    child: const Text('\u91cd\u8bd5'),
                  ),
                ),
              )
            else if (albums == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (albums.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: LegacyNotice(message: '\u6682\u65e0$_title'),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverList.separated(
                  itemCount: albums.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, indent: 80, color: apple.separator),
                  itemBuilder: (BuildContext context, int index) {
                    final Album album = albums[index];
                    final String detail = <String>[
                      if (album.year.isNotEmpty) album.year,
                      if (album.releaseType.isNotEmpty) album.releaseType,
                      if (album.trackCount != null)
                        '${album.trackCount} \u9996',
                    ].join(' \u00b7 ');
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: feedbackAction(
                          context,
                          () => unawaited(
                            openAlbumDetails(context, widget.state, album),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Row(
                            children: <Widget>[
                              LegacyCover(
                                url: album.coverUrl,
                                size: 62,
                                radius: 7,
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      album.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyLarge
                                          ?.copyWith(
                                            color: apple.label,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    if (detail.isNotEmpty) ...<Widget>[
                                      const SizedBox(height: 3),
                                      Text(
                                        detail,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: apple.secondaryLabel,
                                            ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.chevron_right_rounded,
                                color: apple.tertiaryLabel,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }
}

class LegacyArtistSongsPage extends StatefulWidget {
  const LegacyArtistSongsPage({
    super.key,
    required this.state,
    required this.artist,
  });
  final AppState state;
  final ArtistRef artist;

  @override
  State<LegacyArtistSongsPage> createState() => _LegacyArtistSongsPageState();
}

class _LegacyArtistSongsPageState extends State<LegacyArtistSongsPage> {
  List<Track>? _tracks;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load({bool force = false}) async {
    setState(() => _error = null);
    try {
      final tracks = await widget.state.catalog.artistSongs(
        widget.artist.id,
        force: force,
      );
      if (mounted) setState(() => _tracks = tracks);
    } catch (_) {
      try {
        final fallback = await widget.state.catalog.artistDetails(
          widget.artist,
        );
        if (mounted && fallback.tracks.isNotEmpty) {
          setState(() => _tracks = fallback.tracks);
          return;
        }
      } catch (_) {}
      if (mounted) {
        setState(
          () => _error =
              '\u5168\u90e8\u6b4c\u66f2\u52a0\u8f7d\u5931\u8d25\uff0c\u8bf7\u91cd\u8bd5\u3002',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 8),
              sliver: SliverToBoxAdapter(
                child: ApplePageTitle(
                  title: '\u5168\u90e8\u6b4c\u66f2',
                  subtitle: tracks == null
                      ? widget.artist.name
                      : '${widget.artist.name} \u00b7 ${tracks.length} \u9996',
                  padding: EdgeInsets.zero,
                  trailing: tracks == null || tracks.isEmpty
                      ? null
                      : FilledButton.icon(
                          onPressed: () => widget.state.playQueue(tracks),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('\u64ad\u653e'),
                        ),
                ),
              ),
            ),
            if (_error != null)
              SliverToBoxAdapter(
                child: LegacyNotice(
                  message: _error!,
                  action: FilledButton(
                    onPressed: () => unawaited(_load(force: true)),
                    child: const Text('\u91cd\u8bd5'),
                  ),
                ),
              )
            else if (tracks == null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (tracks.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: LegacyNotice(
                  message: '\u6682\u65e0\u53ef\u64ad\u653e\u6b4c\u66f2',
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (BuildContext context, int index) =>
                      LegacyTrackRow(
                        track: tracks[index],
                        index: index,
                        current: widget.state.current?.id == tracks[index].id,
                        playing: widget.state.playing,
                        onTap: () =>
                            widget.state.playQueue(tracks, startIndex: index),
                      ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 36)),
          ],
        ),
      ),
    );
  }
}

/// Horizontal page margin. Phones use the 16 pt iOS inset; windowed layouts
/// breathe with a 24 pt margin, while the content itself is capped below.
double _pageInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 720 ? 16 : 24;

/// Apple-style browse page: a large title, one featured card, a horizontal
/// recommendation shelf and the quick-pick track list.
class LegacyHomePage extends StatelessWidget {
  const LegacyHomePage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final void Function(List<Track> tracks, int index) onPlayTrack;

  @override
  Widget build(BuildContext context) {
    final HomeFeed? feed = state.home;
    if (feed == null) {
      return LegacyNotice(
        message: state.homeError ?? '正在加载曲库…',
        action: state.homeError == null
            ? null
            : FilledButton(
                onPressed: () => unawaited(state.refreshHome(force: true)),
                child: const Text('重试'),
              ),
      );
    }
    final List<Playlist> rail = _uniquePlaylists(<Playlist>[
      ...feed.recommended,
      ...feed.playlists,
    ]);
    final List<Track> tracks = feed.quick.isNotEmpty
        ? feed.quick
        : feed.featuredTracks;
    final String? likedName = state.collections.liked?.name;
    final double inset = _pageInset(context);
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  const ApplePageTitle(
                    title: '现在就听',
                    subtitle: '今天为你整理',
                    padding: EdgeInsets.fromLTRB(0, 12, 0, 16),
                  ),
                  if (rail.isNotEmpty) ...<Widget>[
                    _FeaturedPlaylistCard(
                      playlist: rail.first,
                      onTap: () => onOpenPlaylist(rail.first),
                      compact: compact,
                    ),
                    const SizedBox(height: 8),
                    const LegacySectionHeader(
                      title: '为你推荐',
                      subtitle: '根据你的聆听偏好',
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: compact ? 202 : 224,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        itemCount: rail.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 16),
                        itemBuilder: (BuildContext context, int index) {
                          final Playlist playlist = rail[index];
                          return LegacyPlaylistCard(
                            playlist: playlist,
                            width: compact ? 144 : 168,
                            onTap: () => onOpenPlaylist(playlist),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 26),
                  LegacySectionHeader(
                    title: likedName ?? '继续播放',
                    subtitle: tracks.isEmpty ? null : '${tracks.length} 首',
                  ),
                  const SizedBox(height: 8),
                  if (tracks.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text(
                        '曲库还没有返回可播放的曲目。',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppleSemanticColors.of(context).secondaryLabel,
                        ),
                      ),
                    ),
                ]),
              ),
            ),
            if (tracks.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (BuildContext context, int i) => LegacyTrackRow(
                    track: tracks[i],
                    index: i,
                    current: state.current?.id == tracks[i].id,
                    playing: state.playing,
                    onTap: () => onPlayTrack(tracks, i),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

/// Large recommendation hero. Album art is the content; a bottom scrim keeps
/// white typography legible over any cover.
class _FeaturedPlaylistCard extends StatefulWidget {
  const _FeaturedPlaylistCard({
    required this.playlist,
    required this.onTap,
    required this.compact,
  });

  final Playlist playlist;
  final VoidCallback onTap;
  final bool compact;

  @override
  State<_FeaturedPlaylistCard> createState() => _FeaturedPlaylistCardState();
}

class _FeaturedPlaylistCardState extends State<_FeaturedPlaylistCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String subtitle = <String>[
      if (widget.playlist.trackCount > 0) '${widget.playlist.trackCount} 首歌曲',
      if (widget.playlist.description.isNotEmpty) widget.playlist.description,
    ].join(' · ');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hovering ? 1.004 : 1,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          child: Container(
            height: widget.compact ? 190 : 248,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: apple.separator.withValues(alpha: .4),
                width: .5,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: .16),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (widget.playlist.coverUrl?.isNotEmpty ?? false)
                  LegacyCover(url: widget.playlist.coverUrl, radius: 0)
                else
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: <Color>[
                          apple.accent,
                          Color.lerp(
                            apple.accent,
                            AppleColors.systemPurple,
                            .38,
                          )!,
                        ],
                      ),
                    ),
                  ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[
                        Color(0x00000000),
                        Color(0x33000000),
                        Color(0xD9000000),
                      ],
                      stops: <double>[.2, .54, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: widget.compact ? 18 : 24,
                  right: widget.compact ? 18 : 24,
                  bottom: widget.compact ? 16 : 22,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              '为你精选',
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: Colors.white.withValues(alpha: .72),
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: .4,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.playlist.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -.4,
                                  ),
                            ),
                            if (subtitle.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: Colors.white.withValues(
                                        alpha: .72,
                                      ),
                                    ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(
                            alpha: _hovering ? 1 : .86,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_arrow_rounded,
                          size: 27,
                          color: Colors.black,
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
    );
  }
}

/// Library: owned playlists followed by public recommendations.
class LegacyLibraryPage extends StatelessWidget {
  const LegacyLibraryPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    final UserCollections collections = state.collections;
    final List<Playlist> mine = _uniquePlaylists(<Playlist>[
      if (collections.liked != null) collections.liked!,
      ...collections.created,
      ...collections.subscribed,
    ]);
    final List<Playlist> publicLists = _uniquePlaylists(
      state.home?.playlists ?? const <Playlist>[],
    );
    if (mine.isEmpty && publicLists.isEmpty) {
      return LegacyNotice(
        message: state.isGuest ? '登录后同步你的歌单' : '还没有歌单。',
        action: state.isGuest
            ? FilledButton(
                onPressed: () =>
                    unawaited(showLegacyLoginDialog(context, state)),
                child: const Text('登录'),
              )
            : null,
      );
    }
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 28),
          children: <Widget>[
            ApplePageTitle(
              title: '资料库',
              subtitle: state.isGuest ? '登录后同步你的歌单' : '${state.user.name} 的音乐',
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 18),
            ),
            if (mine.isNotEmpty) ...<Widget>[
              LegacySectionHeader(
                title: '我的音乐',
                subtitle: state.isGuest ? '游客模式' : null,
                trailing: state.signedIn
                    ? IconButton(
                        tooltip: '刷新歌单',
                        onPressed: () =>
                            unawaited(state.refreshCollections(force: true)),
                        icon: const Icon(Icons.sync_rounded, size: 19),
                      )
                    : null,
              ),
              const SizedBox(height: 14),
              LegacyPlaylistGrid(playlists: mine, onOpen: onOpenPlaylist),
              const SizedBox(height: 34),
            ],
            if (publicLists.isNotEmpty) ...<Widget>[
              const LegacySectionHeader(title: '推荐歌单'),
              const SizedBox(height: 14),
              LegacyPlaylistGrid(
                playlists: publicLists,
                onOpen: onOpenPlaylist,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The liked-songs library entry.
class LegacyLikesPage extends StatelessWidget {
  const LegacyLikesPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    if (state.isGuest) {
      return LegacyNotice(
        message: '登录后查看喜欢的音乐。',
        icon: Icons.favorite_border_rounded,
        action: FilledButton(
          onPressed: () => unawaited(showLegacyLoginDialog(context, state)),
          child: const Text('登录'),
        ),
      );
    }
    final Playlist? liked = state.collections.liked;
    if (liked == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LegacyPlaylistPage(state: state, playlist: liked, embedded: true);
  }
}

/// One playlist with the Apple Music large album header and track list.
class LegacyPlaylistPage extends StatefulWidget {
  const LegacyPlaylistPage({
    super.key,
    required this.state,
    required this.playlist,
    this.embedded = false,
    this.album,
  });

  final AppState state;
  final Playlist playlist;
  final bool embedded;

  /// When set, the page loads album tracks instead of playlist tracks. The
  /// album still travels through [playlist] for the header and title, so both
  /// details share one implementation.
  final Album? album;

  @override
  State<LegacyPlaylistPage> createState() => _LegacyPlaylistPageState();
}

class _LegacyPlaylistPageState extends State<LegacyPlaylistPage> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  final ValueNotifier<bool> _showLocate = ValueNotifier<bool>(false);
  bool _refreshScheduled = false;
  List<Track>? _tracks;
  String? _note;
  String? _error;
  List<double>? _rowTops;
  List<double>? _rowHeights;
  bool _metricsDirty = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scheduleLocateRefresh);
    widget.state.addListener(_scheduleLocateRefresh);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _metricsDirty = true;
    _scheduleLocateRefresh();
  }

  @override
  void dispose() {
    _scroll.removeListener(_scheduleLocateRefresh);
    widget.state.removeListener(_scheduleLocateRefresh);
    _showLocate.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final Album? album = widget.album;
      final List<Track> tracks;
      String? note;
      if (album != null) {
        // The list row only carries a stub Album; the full description lives
        // on the album detail endpoint.
        final details = await widget.state.catalog.albumDetails(
          int.parse(album.id),
        );
        tracks = details.tracks;
        note = details.description;
      } else {
        tracks = await widget.state.catalog.playlistTracks(widget.playlist.id);
      }
      if (!mounted) return;
      setState(() {
        _tracks = tracks;
        _note = note;
        _metricsDirty = true;
      });
      _scheduleLocateRefresh();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '歌单读取失败，请重试。');
    }
  }

  /// Natural height of one [LegacyTrackRow]: 44 px cover, three optional text
  /// lines and the row's vertical padding/margin. Measured rather than
  /// hard-coded so text scaling stays exact.
  double _rowExtent(Track track, ThemeData theme, TextScaler scaler) {
    double line(TextStyle? style, String text) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final double height = painter.height;
      painter.dispose();
      return height;
    }

    final double title = line(theme.textTheme.bodyMedium, track.title);
    final double artist = line(theme.textTheme.bodySmall, track.artist);
    final String? translated = track.translatedTitle?.trim();
    final double translation = translated == null || translated.isEmpty
        ? 0
        : line(theme.textTheme.bodySmall, translated);
    return math.max(44.0, title + artist + translation) + 16.0;
  }

  void _ensureRowMetrics() {
    final List<Track>? tracks = _tracks;
    if (tracks == null) {
      _rowTops = null;
      _rowHeights = null;
      return;
    }
    if (!_metricsDirty &&
        _rowTops?.length == tracks.length &&
        _rowHeights?.length == tracks.length) {
      return;
    }
    final ThemeData theme = Theme.of(context);
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final List<double> tops = <double>[];
    final List<double> heights = <double>[];
    var offset = 0.0;
    for (final Track track in tracks) {
      tops.add(offset);
      final double extent = _rowExtent(track, theme, scaler);
      heights.add(extent);
      offset += extent;
    }
    _rowTops = tops;
    _rowHeights = heights;
    _metricsDirty = false;
  }

  int _currentIndex(List<Track> tracks) {
    final Track? current = widget.state.current;
    return current == null
        ? -1
        : tracks.indexWhere((Track track) => track.id == current.id);
  }

  void _scheduleLocateRefresh() {
    if (_refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      _refreshLocate();
    });
  }

  void _refreshLocate() {
    if (!mounted) return;
    final bool show = _shouldShowLocate();
    if (_showLocate.value != show) _showLocate.value = show;
  }

  /// Show the locator only when the playing track belongs to this playlist
  /// and its row is currently outside the visible scroll range.
  bool _shouldShowLocate() {
    final List<Track>? tracks = _tracks;
    if (tracks == null || tracks.isEmpty || !_scroll.hasClients) return false;
    final int index = _currentIndex(tracks);
    if (index < 0) return false;
    _ensureRowMetrics();
    final List<double>? tops = _rowTops;
    final List<double>? heights = _rowHeights;
    final double? header = _headerKey.currentContext?.size?.height;
    if (tops == null || heights == null || header == null) return false;
    final double top = 12 + header + tops[index];
    final double bottom = top + heights[index];
    final double viewTop = _scroll.offset;
    final double viewBottom = viewTop + _scroll.position.viewportDimension;
    return bottom <= viewTop || top >= viewBottom;
  }

  Future<void> _locateCurrent() async {
    final List<Track>? tracks = _tracks;
    if (tracks == null || tracks.isEmpty || !_scroll.hasClients) return;
    final int index = _currentIndex(tracks);
    if (index < 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前歌曲不在这个歌单中')));
      return;
    }
    _ensureRowMetrics();
    final List<double>? tops = _rowTops;
    final List<double>? heights = _rowHeights;
    if (tops == null || heights == null) return;
    final double header = _headerKey.currentContext?.size?.height ?? 0;
    final double top = 12 + header + tops[index];
    final double extent = heights[index];
    final double viewport = _scroll.position.viewportDimension;
    final double target = (top - (viewport - extent) / 2).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Track>? tracks = _tracks;
    final double inset = _pageInset(context);
    final bool compact = MediaQuery.sizeOf(context).width < 680;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomScrollView(
              controller: _scroll,
              slivers: <Widget>[
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(inset, 12, inset, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      key: _headerKey,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _PlaylistHeader(
                          playlist: widget.playlist,
                          compact: compact,
                          artist: widget.album?.artist,
                          artistWidget: widget.album == null
                              ? null
                              : ArtistNameLink(
                                  state: widget.state,
                                  artists: widget.album!.artists,
                                  fallback: widget.album!.artist,
                                ),
                          note: _note ?? widget.album?.note,
                          onPlay: tracks == null || tracks.isEmpty
                              ? null
                              : () => widget.state.playQueue(tracks),
                        ),
                        const SizedBox(height: 22),
                        if (_error != null)
                          LegacyNotice(
                            message: _error!,
                            action: FilledButton(
                              onPressed: () => unawaited(_load()),
                              child: const Text('重试'),
                            ),
                          )
                        else if (tracks == null)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 52),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (tracks.isEmpty)
                          const LegacyNotice(message: '这个歌单还没有可播放的曲目。')
                        else
                          LegacySectionHeader(
                            title: '歌曲',
                            subtitle: '${tracks.length} 首',
                          ),
                        const SizedBox(height: 6),
                      ],
                    ),
                  ),
                ),
                if (tracks != null && tracks.isNotEmpty)
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverList.builder(
                      itemCount: tracks.length,
                      itemBuilder: (BuildContext context, int i) =>
                          LegacyTrackRow(
                            key: ValueKey<String>('playlist-row-$i'),
                            track: tracks[i],
                            index: i,
                            current: widget.state.current?.id == tracks[i].id,
                            playing: widget.state.playing,
                            onTap: () =>
                                widget.state.playQueue(tracks, startIndex: i),
                          ),
                    ),
                  ),
                // Leave room for the floating locate button so the last row
                // can scroll clear of it.
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
              ],
            ),
            Positioned(
              right: 18,
              bottom: 18,
              child: ValueListenableBuilder<bool>(
                valueListenable: _showLocate,
                builder: (BuildContext context, bool show, Widget? _) {
                  if (!show) return const SizedBox.shrink();
                  return FloatingActionButton.small(
                    key: const ValueKey<String>('playlist-locate'),
                    heroTag: null,
                    tooltip: '定位正在播放',
                    backgroundColor: AppleSemanticColors.of(context).accent,
                    foregroundColor: Colors.white,
                    onPressed: () => unawaited(_locateCurrent()),
                    child: const Icon(Icons.my_location_rounded, size: 20),
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

class _PlaylistHeader extends StatelessWidget {
  const _PlaylistHeader({
    required this.playlist,
    required this.compact,
    required this.onPlay,
    this.artist,
    this.artistWidget,
    this.note,
  });

  final Playlist playlist;
  final bool compact;
  final VoidCallback? onPlay;

  /// Album-only extras. A playlist leaves both null and renders as before.
  final String? artist;

  /// Replaces the plain artist line when the caller can make it a link.
  final Widget? artistWidget;
  final String? note;

  static Future<void> _showNote(BuildContext context, String note) =>
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('专辑简介'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(child: Text(note)),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double coverSize = compact ? 168 : 190;
    final Widget stillCover = LegacyCover(
      url: playlist.coverUrl,
      size: coverSize,
      radius: 14,
    );
    final Widget cover = RepaintBoundary(
      // Albums try Apple's motion artwork; playlists keep the still cover.
      child: artist == null
          ? stillCover
          : MotionArtwork(
              size: coverSize,
              radius: 14,
              artist: artist,
              album: playlist.name,
              child: stillCover,
            ),
    );
    final Widget? summary = note == null || note!.trim().isEmpty
        ? null
        : GestureDetector(
            onTap: () => _showNote(context, note!),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Text(
                note!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: compact ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: apple.tertiaryLabel,
                  height: 1.5,
                ),
              ),
            ),
          );
    final Widget info = Column(
      crossAxisAlignment: compact
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: <Widget>[
        // Albums stack the title, artist and summary against the transport row
        // instead of the cover's top edge.
        if (!compact && artistWidget != null) const Spacer(),
        Text(
          playlist.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: compact ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.headlineLarge?.copyWith(
            color: apple.label,
            fontWeight: FontWeight.w700,
            letterSpacing: -.6,
          ),
        ),
        if (artistWidget != null) ...[
          const SizedBox(height: 4),
          artistWidget!,
        ] else if (artist != null) ...[
          const SizedBox(height: 4),
          Text(
            artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.titleMedium?.copyWith(
              color: apple.secondaryLabel,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        // Albums drop the count line: it only forced a blank row between the
        // artist and the summary.
        if (artist == null) ...[
          const SizedBox(height: 7),
          Text(
            <String>[
              if (playlist.trackCount > 0) '${playlist.trackCount} 首歌曲',
              if (playlist.description.isNotEmpty) playlist.description,
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: compact ? TextAlign.center : TextAlign.start,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ],
        // Desktop spends the leftover height on the summary, which is what
        // pins the transport row to the cover's bottom edge. Compact layouts
        // have no bounded height, so they keep a plain three-line block.
        if (summary != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: summary),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('播放全部'),
            ),
            const SizedBox(width: 10),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: apple.fill,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.shuffle_rounded,
                size: 19,
                color: onPlay == null ? apple.tertiaryLabel : apple.accent,
              ),
            ),
          ],
        ),
      ],
    );
    if (compact) {
      return Column(
        children: <Widget>[cover, const SizedBox(height: 18), info],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        cover,
        const SizedBox(width: 24),
        Expanded(
          child: SizedBox(height: coverSize, child: info),
        ),
      ],
    );
  }
}

/// Search page reached from the rail (desktop) or the 搜索 tab (phones).
///
/// The field lives here rather than in the toolbar, so the page owns the
/// query, the debounce and the results. Switching pages disposes it, which is
/// also what resets the search.
class LegacySearchPage extends StatefulWidget {
  const LegacySearchPage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;

  @override
  State<LegacySearchPage> createState() => _LegacySearchPageState();
}

class _LegacySearchPageState extends State<LegacySearchPage> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  SearchResults? _results;
  String _query = '';
  bool _loading = false;
  String? _error;
  int _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      unawaited(_run(value.trim()));
    });
    // Rebuild right away for the clear affordance; the query stays debounced.
    setState(() {});
  }

  void _clear() {
    _debounce?.cancel();
    _search.clear();
    _generation++;
    setState(() {
      _query = '';
      _results = null;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _run(String query) async {
    final int generation = ++_generation;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _results = null;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _query = query;
      _loading = true;
      _error = null;
    });
    try {
      final SearchResults results = await widget.state.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '搜索失败，请检查网络后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 14, inset, 12),
              child: AppleSearchField(
                controller: _search,
                autofocus: true,
                onChanged: _onChanged,
                onClear: _clear,
              ),
            ),
            Expanded(child: _body(inset)),
          ],
        ),
      ),
    );
  }

  Widget _body(double inset) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LegacyNotice(
        message: _error!,
        icon: Icons.search_off_rounded,
        action: FilledButton(
          onPressed: () => unawaited(_run(_query)),
          child: const Text('重试'),
        ),
      );
    }
    final SearchResults? results = _results;
    if (_query.isEmpty) {
      return const LegacyNotice(
        message: '搜索歌曲、歌手或歌单。',
        icon: Icons.search_rounded,
      );
    }
    if (results == null || results.hits == 0) {
      return const LegacyNotice(
        message: '没有找到相关结果。',
        icon: Icons.search_rounded,
      );
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
      children: <Widget>[
        if (results.tracks.isNotEmpty) ...<Widget>[
          LegacySectionHeader(
            title: '单曲',
            subtitle: '${results.tracks.length} 首',
          ),
          const SizedBox(height: 8),
          for (int i = 0; i < results.tracks.length; i++)
            LegacyTrackRow(
              track: results.tracks[i],
              index: i,
              current: widget.state.current?.id == results.tracks[i].id,
              playing: widget.state.playing,
              onTap: () =>
                  widget.state.playQueue(results.tracks, startIndex: i),
            ),
          const SizedBox(height: 28),
        ],
        if (results.playlists.isNotEmpty) ...<Widget>[
          const LegacySectionHeader(title: '歌单'),
          const SizedBox(height: 14),
          LegacyPlaylistGrid(
            playlists: results.playlists,
            onOpen: widget.onOpenPlaylist,
          ),
        ],
      ],
    );
  }
}

/// A single-column, inset-grouped Settings page, following the iOS Settings
/// information architecture rather than a desktop form grid.
class LegacySettingsPage extends StatelessWidget {
  const LegacySettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final double minScale = UiMetrics.minScaleOf(context);
    final double shownScale = UiMetrics.scaleOf(context);
    final bool car = UiMetrics.carOf(context);
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 36),
          children: <Widget>[
            const ApplePageTitle(
              title: '设置',
              subtitle: '外观、界面和账户。',
              padding: EdgeInsets.fromLTRB(0, 12, 0, 20),
            ),
            const _LegacySectionLabel('界面'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '配色',
                    subtitle: state.legacyPalette.detail,
                    trailing: DropdownButton<LegacyPaletteMode>(
                      value: state.legacyPalette,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<LegacyPaletteMode>>[
                        for (final LegacyPaletteMode mode
                            in LegacyPaletteMode.values)
                          DropdownMenuItem<LegacyPaletteMode>(
                            value: mode,
                            child: Text(mode.label),
                          ),
                      ],
                      onChanged: (LegacyPaletteMode? value) {
                        if (value != null) {
                          unawaited(state.setLegacyPalette(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '设备形态',
                    subtitle: state.surface.detail,
                    trailing: DropdownButton<AppSurface>(
                      value: state.surface,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppSurface>>[
                        for (final AppSurface surface in AppSurface.values)
                          DropdownMenuItem<AppSurface>(
                            value: surface,
                            child: Text(surface.label),
                          ),
                      ],
                      onChanged: (AppSurface? value) {
                        if (value != null) unawaited(state.setSurface(value));
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '界面布局',
                    subtitle: state.uiMode.detail,
                    trailing: DropdownButton<AppUiMode>(
                      value: state.uiMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppUiMode>>[
                        for (final AppUiMode mode in AppUiMode.values)
                          DropdownMenuItem<AppUiMode>(
                            value: mode,
                            child: Text(mode.label),
                          ),
                      ],
                      onChanged: (AppUiMode? value) {
                        if (value != null) unawaited(state.setUiMode(value));
                      },
                    ),
                  ),
                  _LegacySliderRow(
                    key: const ValueKey('dpi-scale-slider'),
                    label: 'DPI 缩放',
                    valueText: '${(shownScale * 100).round()}%',
                    subtitle: state.autoDpiScale
                        ? '自动推算 · 拖动拉杆即改为手动'
                        : car
                        ? '车机形态已把界面放大到 ${(minScale * 100).round()}% 起'
                        : '按比例放大整块界面，适合高分屏',
                    value: shownScale.clamp(minScale, kDpiScaleMax),
                    min: minScale,
                    max: kDpiScaleMax,
                    divisions: ((kDpiScaleMax - minScale) / kDpiScaleStep)
                        .round(),
                    onChanged: (double value) =>
                        unawaited(state.setDpiScale(value)),
                    action: TextButton(
                      key: const ValueKey('dpi-scale-reset'),
                      onPressed: () => unawaited(state.resetDpiScale()),
                      child: const Text('恢复默认'),
                    ),
                  ),
                  _LegacySwitchRow(
                    key: const ValueKey('auto-dpi-switch'),
                    label: '自动调节 DPI 缩放',
                    subtitle: '按窗口可用空间自动推算',
                    value: state.autoDpiScale,
                    onChanged: (bool value) =>
                        unawaited(state.setAutoDpiScale(value)),
                  ),
                  _LegacySettingRow(
                    label: '背景',
                    subtitle: '使用当前歌曲封面主色渲染整页画布',
                    trailing: DropdownButton<LegacyBackgroundMode>(
                      value: state.legacyBackground,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<LegacyBackgroundMode>>[
                        for (final LegacyBackgroundMode mode
                            in LegacyBackgroundMode.values)
                          DropdownMenuItem<LegacyBackgroundMode>(
                            value: mode,
                            child: Text(mode.label),
                          ),
                      ],
                      onChanged: (LegacyBackgroundMode? value) {
                        if (value != null) {
                          unawaited(state.setLegacyBackground(value));
                        }
                      },
                    ),
                  ),
                  _LegacySliderRow(
                    key: const ValueKey('legacy-ui-alpha'),
                    label: '内容不透明度',
                    valueText: '${(state.legacyUiAlpha * 100).round()}%',
                    subtitle: '数值越小，封面主色越明显',
                    value: state.legacyUiAlpha.clamp(0.4, 1.0),
                    min: 0.4,
                    max: 1.0,
                    divisions: 12,
                    onChanged:
                        state.legacyBackground == LegacyBackgroundMode.off
                        ? null
                        : (double value) =>
                              unawaited(state.setLegacyUiAlpha(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('外观'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: '主题',
                    subtitle: switch (state.themeMode) {
                      ThemeMode.system => '跟随系统',
                      ThemeMode.light => '浅色',
                      ThemeMode.dark => '深色',
                    },
                    trailing: DropdownButton<ThemeMode>(
                      value: state.themeMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: const <DropdownMenuItem<ThemeMode>>[
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.system,
                          child: Text('跟随系统'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.light,
                          child: Text('浅色'),
                        ),
                        DropdownMenuItem<ThemeMode>(
                          value: ThemeMode.dark,
                          child: Text('深色'),
                        ),
                      ],
                      onChanged: (ThemeMode? value) {
                        if (value != null) {
                          unawaited(state.setThemeMode(value));
                        }
                      },
                    ),
                  ),
                  _LegacySettingRow(
                    label: '语言',
                    subtitle: state.language.name,
                    trailing: DropdownButton<AppLanguage>(
                      value: state.language,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(12),
                      items: <DropdownMenuItem<AppLanguage>>[
                        for (final AppLanguage language in AppLanguage.values)
                          DropdownMenuItem<AppLanguage>(
                            value: language,
                            child: Text(language.name),
                          ),
                      ],
                      onChanged: (AppLanguage? value) {
                        if (value != null) {
                          unawaited(state.setLanguage(value));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('播放'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: _LegacySwitchRow(
                label: '独立播放',
                subtitle: '不接入系统媒体控制',
                value: state.independentPlayback,
                onChanged: (bool value) =>
                    unawaited(state.setIndependentPlayback(value)),
              ),
            ),
            const _LegacySectionLabel('交互'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySwitchRow(
                    label: '震动反馈',
                    subtitle: '点击可操作的元素和拖动进度条、数值条时反馈',
                    value: state.hapticsEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setHapticsEnabled(value)),
                  ),
                  if (defaultTargetPlatform == TargetPlatform.iOS)
                    _LegacySliderRow(
                      label: '震动强度',
                      valueText: '${(state.hapticIntensity * 100).round()}%',
                      value: state.hapticIntensity.clamp(0.0, 1.0),
                      min: 0,
                      max: 1,
                      divisions: 20,
                      onChanged: state.hapticsEnabled
                          ? (double value) =>
                                unawaited(state.setHapticIntensity(value))
                          : null,
                    ),
                  _LegacySliderRow(
                    label: '歌词控件自动隐藏',
                    valueText:
                        '${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '闲置一会儿后收起歌词页的控件',
                    value: state.lyricControlsSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricControlsSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('歌词'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySliderRow(
                    label: '歌词字号',
                    valueText: '${state.lyricFontSize.round()}',
                    value: state.lyricFontSize.clamp(14.0, 40.0),
                    min: 14,
                    max: 40,
                    divisions: 26,
                    onChanged: (double value) =>
                        unawaited(state.setLyricFontSize(value)),
                  ),
                  _LegacyChoiceRow(
                    label: '歌词粗细',
                    valueText: switch (state.lyricFontWeight) {
                      400 => '常规',
                      500 => '中等',
                      600 => '半粗',
                      _ => '粗体',
                    },
                    choices: const <int>[400, 500, 600, 700],
                    selected: state.lyricFontWeight,
                    labelOf: (int weight) => switch (weight) {
                      400 => '常规',
                      500 => '中等',
                      600 => '半粗',
                      _ => '粗体',
                    },
                    onSelected: (int weight) =>
                        unawaited(state.setLyricFontWeight(weight)),
                  ),
                  _LegacySwitchRow(
                    label: '歌词模糊',
                    subtitle: '距离当前歌词越远，模糊越强；手动浏览时渐隐',
                    value: state.lyricBlurEnabled,
                    onChanged: (bool value) =>
                        unawaited(state.setLyricBlurEnabled(value)),
                  ),
                  _LegacySliderRow(
                    label: '手动浏览后恢复跟随',
                    valueText:
                        '${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
                    subtitle: '松开手后多久回到当前行',
                    value: state.lyricResumeSeconds.clamp(1.0, 10.0),
                    min: 1,
                    max: 10,
                    divisions: 18,
                    onChanged: (double value) =>
                        unawaited(state.setLyricResumeSeconds(value)),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('滚动'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySliderRow(
                    label: '滚动惯性',
                    valueText: '${(state.scrollRetention * 100).round()}%',
                    subtitle: '85–98%；数值越高，松手后滑行越久、越远',
                    value: state.scrollRetention,
                    min: ScrollMotion.minRetention,
                    max: ScrollMotion.maxRetention,
                    divisions: 13,
                    onChanged: (double value) =>
                        unawaited(state.setScrollRetention(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollRetention(ScrollMotion.defaultRetention),
                      ),
                      child: const Text('恢复默认'),
                    ),
                  ),
                  _LegacySliderRow(
                    label: '滚动加速度',
                    valueText: '${(state.scrollAcceleration * 100).round()}%',
                    subtitle: '50–300%；数值越高，滚轮和连续甩动提速越明显',
                    value: state.scrollAcceleration,
                    min: ScrollMotion.minAcceleration,
                    max: ScrollMotion.maxAcceleration,
                    divisions: 25,
                    onChanged: (double value) =>
                        unawaited(state.setScrollAcceleration(value)),
                    action: TextButton(
                      onPressed: () => unawaited(
                        state.setScrollAcceleration(
                          ScrollMotion.defaultAcceleration,
                        ),
                      ),
                      child: const Text('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('性能'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySwitchRow(
                    label: '显示帧率',
                    subtitle: '实时显示 UI、GPU、低帧和 100 fps 帧预算',
                    value: state.showFrameStats,
                    onChanged: (bool value) =>
                        unawaited(state.setShowFrameStats(value)),
                  ),
                  _LegacySettingRow(
                    label: '动画帧预算',
                    subtitle: '全部界面动画按 10 ms 设计；低帧目标不低于 90 fps',
                    trailing: Text(
                      '10 ms',
                      style: theme.textTheme.labelMedium?.copyWith(
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
            const _LegacySectionLabel('账户'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: Column(
                children: <Widget>[
                  _LegacySettingRow(
                    label: state.isGuest ? '游客' : state.user.name,
                    subtitle: state.isGuest
                        ? '登录后同步歌单和每日推荐'
                        : state.user.vipLabel ?? '普通用户',
                    trailing: state.isGuest
                        ? FilledButton(
                            onPressed: () => unawaited(
                              showLegacyLoginDialog(context, state),
                            ),
                            child: const Text('登录'),
                          )
                        : TextButton(
                            onPressed: state.signOut,
                            child: const Text('退出登录'),
                          ),
                  ),
                  _LegacySettingRow(
                    label: '刷新曲库',
                    subtitle: '重新拉取首页、歌单和每日推荐',
                    trailing: OutlinedButton(
                      onPressed: () =>
                          unawaited(state.refreshHome(force: true)),
                      child: const Text('刷新'),
                    ),
                  ),
                ],
              ),
            ),
            const _LegacySectionLabel('关于'),
            AppleGroupedCard(
              margin: EdgeInsets.zero,
              child: AppleListTile(
                title: 'Lazer',
                subtitle: 'Apple Music 风格界面 · 自适应桌面与移动端',
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: Image.asset(
                    'assets/app_icon.png',
                    width: 30,
                    height: 30,
                    fit: BoxFit.cover,
                  ),
                ),
                trailing: const Text('2.0'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LegacySectionLabel extends StatelessWidget {
  const _LegacySectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 22, 12, 7),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: apple.secondaryLabel,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _LegacySettingRow extends StatelessWidget {
  const _LegacySettingRow({
    required this.label,
    required this.subtitle,
    required this.trailing,
  });

  final String label;
  final String subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final bool stacked = MediaQuery.sizeOf(context).width < 360;
    final Widget heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.bodyLarge?.copyWith(color: apple.label),
        ),
        if (subtitle.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ],
      ],
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                heading,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(flex: 4, child: heading),
                const SizedBox(width: 12),
                Flexible(
                  flex: 9,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: trailing,
                  ),
                ),
              ],
            ),
    );
  }
}

class _LegacySwitchRow extends StatelessWidget {
  const _LegacySwitchRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return _LegacySettingRow(
      label: label,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: onChanged),
    );
  }
}

class _LegacySliderRow extends StatelessWidget {
  const _LegacySliderRow({
    super.key,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.subtitle,
    this.divisions,
    this.action,
  });

  final String label;
  final String valueText;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double>? onChanged;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 13, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: apple.label,
                  ),
                ),
              ),
              if (action != null) ...<Widget>[
                action!,
                const SizedBox(width: 4),
              ],
              Text(
                valueText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: apple.secondaryLabel,
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: apple.secondaryLabel,
              ),
            ),
          ],
          AccessibleSlider(
            semanticLabel: label,
            label: valueText,
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            detentFeedback: onChanged != null,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _LegacyChoiceRow extends StatelessWidget {
  const _LegacyChoiceRow({
    required this.label,
    required this.valueText,
    required this.choices,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final String label;
  final String valueText;
  final List<int> choices;
  final int selected;
  final String Function(int value) labelOf;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: apple.separator, width: .5)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: apple.label,
                  ),
                ),
              ),
              Text(
                valueText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: apple.secondaryLabel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final int choice in choices)
                ChoiceChip(
                  label: Text(
                    labelOf(choice),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.values[choice ~/ 100 - 1],
                      color: selected == choice ? apple.accent : apple.label,
                    ),
                  ),
                  showCheckmark: false,
                  selected: selected == choice,
                  selectedColor: apple.accentSoft,
                  backgroundColor: apple.fill,
                  side: BorderSide.none,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  onSelected: (_) => onSelected(choice),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Responsive playlist grid shared by Library and Search. It opts into more
/// columns on desktop and two on phones, matching Music's density.
class LegacyPlaylistGrid extends StatelessWidget {
  const LegacyPlaylistGrid({
    super.key,
    required this.playlists,
    required this.onOpen,
  });

  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final int columns = switch (width) {
          >= 1100 => 6,
          >= 860 => 5,
          >= 660 => 4,
          >= 430 => 3,
          _ => 2,
        };
        const double gap = 18;
        final double cell = ((width - gap * (columns - 1)) / columns).clamp(
          112.0,
          180.0,
        );
        return Wrap(
          spacing: gap,
          runSpacing: 24,
          children: <Widget>[
            for (final Playlist playlist in playlists)
              LegacyPlaylistCard(
                playlist: playlist,
                width: cell,
                onTap: () => onOpen(playlist),
              ),
          ],
        );
      },
    );
  }
}

List<Playlist> _uniquePlaylists(List<Playlist> input) {
  final Set<String> seen = <String>{};
  return <Playlist>[
    for (final Playlist playlist in input)
      if (seen.add(playlist.id)) playlist,
  ];
}
