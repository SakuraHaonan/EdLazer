import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, listEquals;
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
import '../state/detail_requests.dart';
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
class LegacyHomePage extends StatefulWidget {
  const LegacyHomePage({
    super.key,
    required this.state,
    required this.onOpenPlaylist,
    required this.onPlayTrack,
    required this.onOpenChart,
  });

  final AppState state;
  final ValueChanged<Playlist> onOpenPlaylist;
  final void Function(List<Track> tracks, int index) onPlayTrack;
  final ValueChanged<MusicChart> onOpenChart;

  @override
  State<LegacyHomePage> createState() => _LegacyHomePageState();
}

class _LegacyHomePageState extends State<LegacyHomePage> {
  bool _startingStation = false;

  Future<void> _playStation(Future<List<Track>> Function() load) async {
    if (_startingStation) return;
    setState(() => _startingStation = true);
    try {
      final tracks = await load();
      if (!mounted) return;
      if (tracks.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时没有可播放的歌曲')));
      } else {
        widget.state.playStationQueue(tracks, loadMore: load);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('播放队列加载失败，请稍后重试')));
      }
    } finally {
      if (mounted) setState(() => _startingStation = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final HomeFeed? feed = widget.state.home;
    if (feed == null) {
      return LegacyNotice(
        message: widget.state.homeError ?? '正在加载曲库…',
        action: widget.state.homeError == null
            ? null
            : FilledButton(
                onPressed: () =>
                    unawaited(widget.state.refreshHome(force: true)),
                child: const Text('重试'),
              ),
      );
    }
    final List<Playlist> recommendations = _uniquePlaylists(feed.recommended);
    final List<Track> recent = widget.state.recentTracks;
    final ArtistRef? stationArtist = recent
        .expand((track) => track.artists)
        .where((artist) => artist.id > 0)
        .firstOrNull;
    final double inset = _pageInset(context);
    final bool compact = MediaQuery.sizeOf(context).width < 720;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          key: const PageStorageKey<String>('discovery-scroll'),
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  _HomeActionShelf(
                    busy: _startingStation,
                    covers: <String?>[
                      ...recent.map((track) => track.coverUrl),
                      ...feed.quick.map((track) => track.coverUrl),
                      ...feed.albums.map((album) => album.coverUrl),
                    ],
                    onDaily: !widget.state.signedIn || feed.quick.isEmpty
                        ? null
                        : () => widget.state.playQueue(feed.quick),
                    onFm: widget.state.signedIn
                        ? () => _playStation(
                            widget.state.catalog.personalFmTracks,
                          )
                        : null,
                    onHeart: widget.state.collections.liked == null
                        ? null
                        : () => _playStation(
                            () => widget.state.catalog.heartModeTracks(
                              widget.state.collections.liked!,
                            ),
                          ),
                    onReplay: recent.isEmpty
                        ? null
                        : () => widget.state.playQueue(recent),
                  ),
                  const SizedBox(height: 34),
                  LegacySectionHeader(title: '最近播放'),
                  const SizedBox(height: 10),
                  if (recent.isNotEmpty)
                    _HomeTrackGrid(
                      state: widget.state,
                      tracks: recent,
                      onPlay: widget.onPlayTrack,
                    )
                  else
                    const LegacyNotice(message: '还没有最近播放记录'),
                  if (feed.albums.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 36),
                    const LegacySectionHeader(title: '为你推荐的新发行'),
                    const SizedBox(height: 14),
                    _HomeReleaseShelf(
                      state: widget.state,
                      albums: feed.albums,
                      compact: compact,
                    ),
                  ],
                  if (feed.editorialPlaylists.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const LegacySectionHeader(title: '网易云编辑精选'),
                    const SizedBox(height: 14),
                    _EditorialPlaylistShelf(
                      playlists: feed.editorialPlaylists,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  const SizedBox(height: 38),
                  const LegacySectionHeader(title: '排行榜'),
                  const SizedBox(height: 14),
                  if (widget.state.discoveryCharts.isNotEmpty)
                    _ChartShelf(
                      charts: widget.state.discoveryCharts,
                      onOpen: widget.onOpenChart,
                      compact: compact,
                    )
                  else
                    _ChartLoadCard(
                      loading: widget.state.discoveryChartsLoading,
                      message: widget.state.discoveryChartsError,
                      onRetry: () => unawaited(
                        widget.state.refreshDiscoveryCharts(force: true),
                      ),
                    ),
                  if (recommendations.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 38),
                    const LegacySectionHeader(title: '猜你喜欢'),
                    const SizedBox(height: 14),
                    _RecommendationShelf(
                      playlists: recommendations,
                      onOpen: widget.onOpenPlaylist,
                      compact: compact,
                    ),
                  ],
                  const SizedBox(height: 38),
                  LegacySectionHeader(title: '为你创建的电台'),
                  const SizedBox(height: 14),
                  _StationStrip(
                    enabled: widget.state.signedIn,
                    covers: <String?>[
                      ...recent.map((track) => track.coverUrl),
                      ...feed.quick.map((track) => track.coverUrl),
                      ...feed.albums.map((album) => album.coverUrl),
                    ],
                    onFm: () =>
                        _playStation(widget.state.catalog.personalFmTracks),
                    onLiked: widget.state.collections.liked == null
                        ? null
                        : () => _playStation(() async {
                            final tracks = await widget.state.catalog
                                .playlistTracks(
                                  widget.state.collections.liked!.id,
                                );
                            return List<Track>.of(tracks)..shuffle();
                          }),
                    onHeart: widget.state.collections.liked == null
                        ? null
                        : () => _playStation(
                            () => widget.state.catalog.heartModeTracks(
                              widget.state.collections.liked!,
                            ),
                          ),
                    artistName: stationArtist?.name,
                    onArtist: stationArtist == null
                        ? null
                        : () => _playStation(
                            () => widget.state.catalog.artistStationTracks(
                              stationArtist,
                            ),
                          ),
                  ),
                ]),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
          ],
        ),
      ),
    );
  }
}

class _HomeActionShelf extends StatelessWidget {
  const _HomeActionShelf({
    required this.busy,
    required this.covers,
    this.onDaily,
    this.onFm,
    this.onHeart,
    this.onReplay,
  });

  final bool busy;
  final List<String?> covers;
  final VoidCallback? onDaily;
  final VoidCallback? onFm;
  final VoidCallback? onHeart;
  final VoidCallback? onReplay;

  @override
  Widget build(BuildContext context) {
    final items =
        <
          ({
            String title,
            String subtitle,
            IconData icon,
            List<Color> colors,
            VoidCallback? tap,
          })
        >[
          (
            title: '每日推荐',
            subtitle: '今日限定好歌',
            icon: Icons.calendar_today_rounded,
            colors: const <Color>[Color(0xFFFF375F), Color(0xFFFF7A45)],
            tap: onDaily,
          ),
          (
            title: '私人漫游',
            subtitle: '发现没听过的音乐',
            icon: Icons.waves_rounded,
            colors: const <Color>[Color(0xFF7357FF), Color(0xFF35A7FF)],
            tap: onFm,
          ),
          (
            title: '心动模式',
            subtitle: '红心与相似推荐',
            icon: Icons.favorite_rounded,
            colors: const <Color>[Color(0xFFE5488A), Color(0xFF8C52FF)],
            tap: onHeart,
          ),
          (
            title: '反复聆听',
            subtitle: '回到你爱的歌',
            icon: Icons.replay_rounded,
            colors: const <Color>[Color(0xFF087E8B), Color(0xFF42C98B)],
            tap: onReplay,
          ),
        ];
    return _PagedHorizontalShelf(
      key: const ValueKey<String>('home-actions'),
      height: 164,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _HomeActionCard(
          title: item.title,
          subtitle: item.subtitle,
          icon: item.icon,
          colors: item.colors,
          covers: covers.isEmpty
              ? const <String?>[]
              : <String?>[
                  for (var offset = 0; offset < covers.length; offset++)
                    covers[(index * 2 + offset) % covers.length],
                ],
          onTap: busy ? null : item.tap,
        );
      },
    );
  }
}

class _HomeActionCard extends StatefulWidget {
  const _HomeActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.colors,
    required this.covers,
    this.onTap,
  });
  final String title;
  final String subtitle;
  final IconData icon;
  final List<Color> colors;
  final List<String?> covers;
  final VoidCallback? onTap;

  @override
  State<_HomeActionCard> createState() => _HomeActionCardState();
}

class _HomeActionCardState extends State<_HomeActionCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.onTap == null
        ? SystemMouseCursors.basic
        : SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap == null
          ? null
          : feedbackAction(context, widget.onTap!),
      child: AnimatedScale(
        scale: _hover && widget.onTap != null ? 1.015 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Container(
            width: 228,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: widget.onTap == null
                    ? widget.colors
                          .map((color) => color.withValues(alpha: .42))
                          .toList()
                    : widget.colors,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: widget.colors.last.withValues(
                    alpha: _hover ? .28 : .16,
                  ),
                  blurRadius: _hover ? 24 : 16,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Opacity(
                  opacity: widget.onTap == null ? .28 : .52,
                  child: _MovingCoverMosaic(covers: widget.covers),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x18000000), Color(0xD9000000)],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(widget.icon, color: Colors.white, size: 26),
                      const Spacer(),
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.35,
                            ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.subtitle,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: .78),
                          fontWeight: FontWeight.w500,
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

class _PagedHorizontalShelf extends StatefulWidget {
  const _PagedHorizontalShelf({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.gap = 14,
  });

  final double height;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final double gap;

  @override
  State<_PagedHorizontalShelf> createState() => _PagedHorizontalShelfState();
}

class _PagedHorizontalShelfState extends State<_PagedHorizontalShelf> {
  final ScrollController _controller = ScrollController(
    keepScrollOffset: false,
  );

  @override
  void initState() {
    super.initState();
    _refreshAfterLayout();
  }

  @override
  void didUpdateWidget(covariant _PagedHorizontalShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemCount != widget.itemCount ||
        oldWidget.height != widget.height) {
      _refreshAfterLayout();
    }
  }

  void _refreshAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _page(double direction) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasContentDimensions) return;
    final target =
        (position.pixels + position.viewportDimension * .86 * direction).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    _controller.animateTo(
      target,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool desktop = MediaQuery.sizeOf(context).width >= 720;
    return SizedBox(
      height: widget.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ListView.separated(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            physics: const BouncingScrollPhysics(),
            itemCount: widget.itemCount,
            separatorBuilder: (_, _) => SizedBox(width: widget.gap),
            itemBuilder: widget.itemBuilder,
          ),
          if (desktop)
            Positioned.fill(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final bool attached =
                      _controller.hasClients &&
                      _controller.position.hasContentDimensions;
                  final double pixels = attached
                      ? _controller.position.pixels
                      : 0;
                  final double max = attached
                      ? _controller.position.maxScrollExtent
                      : 0;
                  return IgnorePointer(
                    ignoring: !attached || max <= 0,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        _ShelfArrow(
                          icon: Icons.chevron_left_rounded,
                          visible: attached && pixels > 1,
                          onTap: () => _page(-1),
                        ),
                        _ShelfArrow(
                          icon: Icons.chevron_right_rounded,
                          visible: attached && pixels < max - 1,
                          onTap: () => _page(1),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ShelfArrow extends StatelessWidget {
  const _ShelfArrow({
    required this.icon,
    required this.visible,
    required this.onTap,
  });
  final IconData icon;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: visible ? 1 : 0,
    duration: const Duration(milliseconds: 140),
    child: Material(
      color: AppleSemanticColors.of(
        context,
      ).tertiaryBackground.withValues(alpha: .94),
      elevation: 8,
      shadowColor: Colors.black26,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: visible ? onTap : null,
        child: SizedBox.square(dimension: 38, child: Icon(icon, size: 24)),
      ),
    ),
  );
}

class _MovingCoverMosaic extends StatefulWidget {
  const _MovingCoverMosaic({
    required this.covers,
    this.angle = 0,
    this.reverse = false,
    this.rows = 2,
    this.tile = 76,
    this.diagonal = 0,
  });
  final List<String?> covers;
  final double angle;
  final bool reverse;
  final int rows;
  final double tile;
  final double diagonal;

  @override
  State<_MovingCoverMosaic> createState() => _MovingCoverMosaicState();
}

class _MovingCoverMosaicState extends State<_MovingCoverMosaic>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 18),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.stop();
    } else if (!_motion.isAnimating) {
      _motion.repeat();
    }
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final covers = widget.covers
        .where((url) => url?.isNotEmpty ?? false)
        .take(8)
        .toList();
    if (covers.isEmpty) return const SizedBox.expand();
    final repeated = List<String?>.generate(
      math.max(24, widget.rows * 12),
      (index) => covers[index % covers.length],
    );
    final travel = widget.tile * covers.length;
    return AnimatedBuilder(
      animation: _motion,
      builder: (context, child) => Transform.rotate(
        angle: widget.angle,
        child: Transform.translate(
          offset: Offset(
            widget.reverse
                ? -travel + _motion.value * travel
                : -_motion.value * travel,
            (_motion.value - .5) * widget.tile * widget.diagonal,
          ),
          child: child,
        ),
      ),
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        child: SizedBox(
          width: repeated.length * widget.tile / widget.rows,
          height: widget.tile * widget.rows,
          child: Wrap(
            direction: Axis.vertical,
            children: <Widget>[
              for (final url in repeated)
                LegacyCover(url: url, size: widget.tile, radius: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeTrackGrid extends StatelessWidget {
  const _HomeTrackGrid({
    required this.state,
    required this.tracks,
    required this.onPlay,
  });
  final AppState state;
  final List<Track> tracks;
  final void Function(List<Track>, int) onPlay;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      const int rows = 3;
      final int visibleColumns = box.maxWidth >= 920
          ? 3
          : box.maxWidth >= 560
          ? 2
          : 1;
      final List<Track> shown = tracks;
      final int columns = (shown.length / rows).ceil();
      final double width =
          (box.maxWidth - (visibleColumns - 1) * 10) / visibleColumns;
      return _PagedHorizontalShelf(
        key: const ValueKey<String>('recent-tracks'),
        height: rows * 66 + (rows - 1) * 8,
        gap: 10,
        itemCount: columns,
        itemBuilder: (context, column) => SizedBox(
          width: width,
          child: Column(
            children: <Widget>[
              for (var row = 0; row < rows; row++) ...<Widget>[
                if (row > 0) const SizedBox(height: 8),
                if (column * rows + row < shown.length)
                  _ArtistTrackCard(
                    track: shown[column * rows + row],
                    current: state.current?.id == shown[column * rows + row].id,
                    onTap: () => onPlay(shown, column * rows + row),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _HomeReleaseShelf extends StatelessWidget {
  const _HomeReleaseShelf({
    required this.state,
    required this.albums,
    required this.compact,
  });
  final AppState state;
  final List<Album> albums;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('new-releases'),
    height: compact ? 204 : 226,
    itemCount: albums.length,
    gap: 16,
    itemBuilder: (context, index) {
      final album = albums[index];
      final double size = compact ? 146 : 168;
      return SizedBox(
        width: size,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: feedbackAction(
            context,
            () => unawaited(openAlbumDetails(context, state, album)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LegacyCover(url: album.coverUrl, size: size, radius: 11),
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
                album.artist,
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
  );
}

class _EditorialPlaylistShelf extends StatelessWidget {
  const _EditorialPlaylistShelf({
    required this.playlists,
    required this.onOpen,
    required this.compact,
  });
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('editorial-playlists'),
    height: compact ? 190 : 214,
    itemCount: playlists.length,
    gap: 16,
    itemBuilder: (context, index) {
      final playlist = playlists[index];
      return SizedBox(
        width: compact ? 270 : 330,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: feedbackAction(context, () => onOpen(playlist)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                LegacyCover(url: playlist.coverUrl, radius: 0),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x11000000), Color(0xD9000000)],
                      stops: <double>[.25, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: 18,
                  right: 18,
                  bottom: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '网易云编辑精选',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ChartShelf extends StatelessWidget {
  const _ChartShelf({
    required this.charts,
    required this.onOpen,
    required this.compact,
  });
  final List<MusicChart> charts;
  final ValueChanged<MusicChart> onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('charts'),
    height: compact ? 274 : 294,
    itemCount: charts.length,
    gap: 16,
    itemBuilder: (context, index) {
      final chart = charts[index];
      return SizedBox(
        width: compact ? 246 : 278,
        child: Material(
          color: Colors.black,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: feedbackAction(context, () => onOpen(chart)),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                Transform.scale(
                  scale: 1.32,
                  child: _MovingCoverMosaic(
                    covers: chart.entries
                        .map(_chartEntryCover)
                        .toList(growable: false),
                    angle: -.11,
                    reverse: true,
                    rows: 4,
                    tile: 82,
                    diagonal: -.55,
                  ),
                ),
                ColoredBox(color: Colors.black.withValues(alpha: .68)),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0x12000000), Color(0xF2000000)],
                      stops: <double>[.22, 1],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _ChartLogo(chart: chart),
                      const Spacer(),
                      Text(
                        chart.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -.6,
                            ),
                      ),
                      Text(
                        chart.issueLabel,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                      ),
                      const SizedBox(height: 9),
                      for (final entry in chart.entries.take(3))
                        Padding(
                          padding: const EdgeInsets.only(top: 5),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: 24,
                                child: Text(
                                  '${entry.rank}',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  entry.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

String? _chartEntryCover(ChartEntry entry) =>
    entry.track?.coverUrl ?? entry.coverUrl;

String _chartBrand(MusicChart chart) {
  final title = chart.title.toLowerCase();
  if (title.contains('billboard')) return 'billboard';
  if ((chart.providerKey ?? '').startsWith('biliboard:')) return 'BILIBOARD';
  if (title.contains('uk')) return 'OFFICIAL CHARTS';
  if (title.contains('beatport')) return 'BEATPORT';
  if (title.contains('oricon')) return 'ORICON';
  if (title.contains('nrj')) return 'NRJ';
  return 'CHARTS';
}

String? _chartLogoAsset(MusicChart chart) {
  final title = chart.title.toLowerCase();
  if (title.contains('billboard')) {
    return 'assets/chart_logos/billboard.png';
  }
  if ((chart.providerKey ?? '').startsWith('biliboard:')) {
    return 'assets/chart_logos/biliboard.png';
  }
  if (title.contains('uk')) {
    return 'assets/chart_logos/official_charts.png';
  }
  if (title.contains('beatport')) {
    return 'assets/chart_logos/beatport.png';
  }
  if (title.contains('oricon')) return 'assets/chart_logos/oricon.png';
  if (title.contains('nrj')) return 'assets/chart_logos/nrj.png';
  return null;
}

class _ChartLogo extends StatelessWidget {
  const _ChartLogo({required this.chart, this.large = false});
  final MusicChart chart;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final asset = _chartLogoAsset(chart);
    final biliboard = (chart.providerKey ?? '').startsWith('biliboard:');
    if (asset == null) {
      return Text(
        _chartBrand(chart),
        style: TextStyle(
          color: Colors.white,
          fontSize: large ? 21 : 16,
          height: 1,
          fontWeight: FontWeight.w900,
          letterSpacing: .5,
        ),
      );
    }
    return SizedBox(
      height: large ? 52 : 38,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Image.asset(
            asset,
            width: large ? (biliboard ? 58 : 190) : (biliboard ? 42 : 144),
            height: large ? 52 : 38,
            alignment: Alignment.centerLeft,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
          ),
          if (biliboard) ...<Widget>[
            SizedBox(width: large ? 10 : 7),
            Text(
              'BiliBoard',
              style: TextStyle(
                color: Colors.white,
                fontSize: large ? 25 : 18,
                height: 1,
                fontWeight: FontWeight.w900,
                letterSpacing: -.6,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecommendationShelf extends StatelessWidget {
  const _RecommendationShelf({
    required this.playlists,
    required this.onOpen,
    required this.compact,
  });
  final List<Playlist> playlists;
  final ValueChanged<Playlist> onOpen;
  final bool compact;

  @override
  Widget build(BuildContext context) => _PagedHorizontalShelf(
    key: const ValueKey<String>('recommendations'),
    height: compact ? 202 : 224,
    itemCount: playlists.length,
    gap: 16,
    itemBuilder: (context, index) => LegacyPlaylistCard(
      playlist: playlists[index],
      width: compact ? 144 : 168,
      onTap: () => onOpen(playlists[index]),
    ),
  );
}

class _StationStrip extends StatelessWidget {
  const _StationStrip({
    required this.enabled,
    required this.onFm,
    required this.covers,
    this.onLiked,
    this.onHeart,
    this.artistName,
    this.onArtist,
  });
  final bool enabled;
  final VoidCallback onFm;
  final List<String?> covers;
  final VoidCallback? onLiked;
  final VoidCallback? onHeart;
  final String? artistName;
  final VoidCallback? onArtist;

  @override
  Widget build(BuildContext context) {
    final stations =
        <({String title, String detail, IconData icon, VoidCallback? tap})>[
          (
            title: '私人漫游',
            detail: '算法探索',
            icon: Icons.radar_rounded,
            tap: enabled ? onFm : null,
          ),
          (
            title: '红心随机',
            detail: '只播放收藏',
            icon: Icons.shuffle_rounded,
            tap: onLiked,
          ),
          (
            title: '心动模式',
            detail: '熟悉与新鲜',
            icon: Icons.favorite_rounded,
            tap: onHeart,
          ),
          if (artistName != null)
            (
              title: '$artistName 电台',
              detail: '相似歌手与曲风',
              icon: Icons.graphic_eq_rounded,
              tap: onArtist,
            ),
        ];
    return _PagedHorizontalShelf(
      key: const ValueKey<String>('stations'),
      height: 154,
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        return _StationCard(
          title: station.title,
          detail: station.detail,
          icon: station.icon,
          covers: covers.isEmpty
              ? const <String?>[]
              : <String?>[
                  for (var offset = 0; offset < covers.length; offset++)
                    covers[(index * 3 + offset) % covers.length],
                ],
          onTap: station.tap,
        );
      },
    );
  }
}

class _StationCard extends StatelessWidget {
  const _StationCard({
    required this.title,
    required this.detail,
    required this.icon,
    required this.covers,
    this.onTap,
  });
  final String title;
  final String detail;
  final IconData icon;
  final List<String?> covers;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 272,
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap == null ? null : feedbackAction(context, onTap!),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(
              color: AppleSemanticColors.of(context).secondaryGroupedBackground,
              child: Opacity(
                opacity: onTap == null ? .18 : .58,
                child: _MovingCoverMosaic(covers: covers),
              ),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x22000000), Color(0xE0000000)],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Icon(icon, color: Colors.white, size: 22),
                      const Icon(
                        Icons.play_circle_fill_rounded,
                        color: Colors.white,
                        size: 29,
                      ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    detail,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChartLoadCard extends StatelessWidget {
  const _ChartLoadCard({
    required this.loading,
    required this.message,
    required this.onRetry,
  });
  final bool loading;
  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Container(
    height: 112,
    padding: const EdgeInsets.symmetric(horizontal: 18),
    decoration: BoxDecoration(
      color: AppleSemanticColors.of(context).secondaryGroupedBackground,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: <Widget>[
        if (loading)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const Icon(Icons.leaderboard_rounded),
        const SizedBox(width: 13),
        Expanded(child: Text(loading ? '正在载入排行榜…' : message ?? '暂无榜单数据')),
        if (!loading) TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    ),
  );
}

class LegacyChartPage extends StatefulWidget {
  const LegacyChartPage({super.key, required this.state, required this.chart});
  final AppState state;
  final MusicChart chart;

  @override
  State<LegacyChartPage> createState() => _LegacyChartPageState();
}

class _LegacyChartPageState extends State<LegacyChartPage> {
  MusicChart? _chart;
  bool _loading = true;
  bool _matching = false;
  int _requestSerial = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final serial = ++_requestSerial;
    final source = widget.chart;
    if (mounted) {
      setState(() {
        _chart = source;
        _loading = false;
        _matching = source.entries.any((entry) => entry.track == null);
      });
    }
    if (source.entries.any((entry) => entry.track == null)) {
      unawaited(_matchInBackground(source, serial));
    }
  }

  Future<void> _matchInBackground(
    MusicChart source,
    int serial, {
    bool force = false,
  }) async {
    try {
      final matched = await widget.state.catalog.prepareChart(
        source,
        force: force,
      );
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = matched;
        _matching = false;
      });
    } catch (_) {
      // Covers, ranks and source links remain usable without a NetEase match.
      if (mounted && serial == _requestSerial) {
        setState(() => _matching = false);
      }
    }
  }

  /// Re-runs the match after a board came back without a single playable row.
  Future<void> _retryMatching() async {
    if (_matching) return;
    final source = _chart ?? widget.chart;
    final serial = ++_requestSerial;
    setState(() => _matching = true);
    await _matchInBackground(source, serial, force: true);
  }

  Future<void> _selectIssue(ChartIssue issue) async {
    final current = _chart ?? widget.chart;
    if (issue.id == current.selectedIssueId || _loading) return;
    final serial = ++_requestSerial;
    setState(() {
      _loading = true;
      _matching = false;
    });
    try {
      final raw = await widget.state.catalog.chartIssue(current, issue);
      if (!mounted || serial != _requestSerial) return;
      setState(() {
        _chart = raw;
        _loading = false;
        _matching = raw.entries.any((entry) => entry.track == null);
      });
      unawaited(_matchInBackground(raw, serial));
    } catch (_) {
      if (mounted && serial == _requestSerial) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这一期暂时载入失败，请稍后重试。')));
      }
    } finally {
      if (mounted && serial == _requestSerial && _loading) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final chart = _chart ?? widget.chart;
    final Color accent = Color(chart.accent);
    final double inset = _pageInset(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Container(
                margin: EdgeInsets.fromLTRB(inset, 20, inset, 28),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      accent,
                      Color.lerp(accent, Colors.black, .66)!,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: accent.withValues(alpha: .2),
                      blurRadius: 30,
                      offset: const Offset(0, 14),
                    ),
                  ],
                ),
                child: _ChartHero(
                  chart: chart,
                  loading: _loading,
                  onIssueSelected: _selectIssue,
                ),
              ),
            ),
            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(bottom: 18),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
            if (!_loading &&
                !_matching &&
                chart.entries.isNotEmpty &&
                chart.entries.every((entry) => entry.track == null))
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                  child: _ChartLoadCard(
                    loading: false,
                    message: '这些歌曲暂时匹配不到网易云，可以重新匹配',
                    onRetry: () => unawaited(_retryMatching()),
                  ),
                ),
              ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 40),
              sliver: SliverList.separated(
                itemCount: chart.entries.length,
                separatorBuilder: (_, _) => const SizedBox(height: 2),
                itemBuilder: (context, index) => _ChartTrackRow(
                  entry: chart.entries[index],
                  matching: _matching && chart.entries[index].track == null,
                  onTap: chart.entries[index].track == null
                      ? null
                      : () => widget.state.playQueue(
                          chart.entries
                              .map((entry) => entry.track)
                              .whereType<Track>()
                              .toList(),
                          startIndex: chart.entries
                              .take(index)
                              .where((entry) => entry.track != null)
                              .length,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartHero extends StatelessWidget {
  const _ChartHero({
    required this.chart,
    required this.loading,
    required this.onIssueSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onIssueSelected;

  Widget _info(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _ChartLogo(chart: chart, large: true),
      const SizedBox(height: 18),
      Text(
        chart.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.displaySmall?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          letterSpacing: -1.1,
        ),
      ),
      const SizedBox(height: 9),
      Row(
        children: <Widget>[
          Flexible(
            child: _ChartIssuePicker(
              chart: chart,
              loading: loading,
              onSelected: onIssueSelected,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${chart.entries.length} 首',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 700;
      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 25, 24, 16),
              child: _info(context),
            ),
            SizedBox(
              height: 178,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
          ],
        );
      }
      return SizedBox(
        height: 286,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: -28,
              right: -24,
              bottom: -28,
              width: constraints.maxWidth * .61,
              child: _ChartHeroArtwork(entries: chart.entries.take(3).toList()),
            ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[
                    Color(0xEE16080D),
                    Color(0xC816080D),
                    Color(0x0016080D),
                  ],
                  stops: <double>[0, .47, .78],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                width: constraints.maxWidth * .52,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(32, 30, 20, 30),
                  child: _info(context),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _ChartHeroArtwork extends StatelessWidget {
  const _ChartHeroArtwork({required this.entries});
  final List<ChartEntry> entries;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final covers = entries.map(_chartEntryCover).toList(growable: false);
      final side = math.min(
        constraints.maxHeight * .78,
        constraints.maxWidth * .42,
      );
      return Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          for (var index = covers.length - 1; index >= 0; index--)
            Positioned(
              left: constraints.maxWidth * (.07 + index * .205),
              top: constraints.maxHeight * (.1 + index * .045),
              child: Transform.rotate(
                angle: (index - 1) * .055,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 28,
                        offset: Offset(0, 14),
                      ),
                    ],
                  ),
                  child: LegacyCover(
                    url: covers[index],
                    size: side,
                    radius: 16,
                    iconSize: 34,
                  ),
                ),
              ),
            ),
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0x00000000), Color(0xB8000000)],
                  stops: <double>[.48, 1],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _ChartIssuePicker extends StatelessWidget {
  const _ChartIssuePicker({
    required this.chart,
    required this.loading,
    required this.onSelected,
  });

  final MusicChart chart;
  final bool loading;
  final ValueChanged<ChartIssue> onSelected;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w700,
    );
    if (chart.issues.length < 2) {
      return Text(chart.issueLabel, style: textStyle);
    }
    return PopupMenuButton<ChartIssue>(
      enabled: !loading,
      tooltip: '选择榜单期数',
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<ChartIssue>>[
        for (final issue in chart.issues)
          PopupMenuItem<ChartIssue>(
            value: issue,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: issue.id == chart.selectedIssueId
                      ? const Icon(Icons.check_rounded, size: 17)
                      : null,
                ),
                const SizedBox(width: 8),
                Text(issue.label),
              ],
            ),
          ),
      ],
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24, width: .5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(chart.issueLabel, style: textStyle),
              const SizedBox(width: 4),
              if (loading)
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 17,
                  color: Colors.white,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartTrackRow extends StatelessWidget {
  const _ChartTrackRow({
    required this.entry,
    this.matching = false,
    this.onTap,
  });
  final ChartEntry entry;
  final bool matching;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final apple = AppleSemanticColors.of(context);
    final roomy = MediaQuery.sizeOf(context).width >= 760;
    final int? previous = entry.previousRank;
    final IconData? trend = switch (entry.changeLabel) {
      'NEW' => Icons.fiber_new_rounded,
      '重返' || '重投' => Icons.replay_rounded,
      _ when previous != null && previous > entry.rank =>
        Icons.arrow_upward_rounded,
      _ when previous != null && previous < entry.rank =>
        Icons.arrow_downward_rounded,
      _ when previous != null => Icons.remove_rounded,
      _ => null,
    };
    return ListTile(
      minTileHeight: 68,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: apple.secondaryGroupedBackground,
      onTap: onTap == null ? null : feedbackAction(context, onTap!),
      leading: SizedBox(
        width: 84,
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 38,
              child: Text(
                '${entry.rank}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                textAlign: TextAlign.right,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 6),
            LegacyCover(
              url: entry.track?.coverUrl ?? entry.coverUrl,
              size: 40,
              radius: 6,
            ),
          ],
        ),
      ),
      title: Text(
        entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        <String>[
          entry.artist.isNotEmpty ? entry.artist : entry.track?.artist ?? '',
          if (entry.peakRank != null) '最高 #${entry.peakRank}',
          if (entry.weeksOnChart != null) '${entry.weeksOnChart} 周',
          if (!roomy && entry.score != null)
            '${_formatChartScore(entry.score!)} 点',
        ].where((value) => value.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (roomy && entry.score != null) ...<Widget>[
            Text(
              '${_formatChartScore(entry.score!)} 点',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: apple.secondaryLabel,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (roomy && entry.trend.length > 1) ...<Widget>[
            SizedBox(
              width: 64,
              height: 28,
              child: CustomPaint(
                painter: _ChartSparklinePainter(
                  values: entry.trend,
                  color: apple.accent,
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (trend != null) Icon(trend, size: 16, color: apple.secondaryLabel),
          if (entry.changeLabel != null) ...<Widget>[
            if (trend != null) const SizedBox(width: 3),
            Text(
              entry.changeLabel!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: apple.secondaryLabel,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if (trend != null || entry.changeLabel != null)
            const SizedBox(width: 10),
          if (matching)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 1.7),
            )
          else
            Icon(
              onTap == null ? Icons.link_off_rounded : Icons.play_arrow_rounded,
              color: onTap == null ? apple.tertiaryLabel : apple.accent,
            ),
        ],
      ),
    );
  }
}

String _formatChartScore(int score) {
  if (score >= 100000000) {
    return '${(score / 100000000).toStringAsFixed(1)}亿';
  }
  if (score >= 10000) return '${(score / 10000).toStringAsFixed(1)}万';
  return '$score';
}

class _ChartSparklinePainter extends CustomPainter {
  const _ChartSparklinePainter({required this.values, required this.color});

  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final span = math.max(1.0, maxValue - minValue);
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - ((values[index] - minValue) / span * size.height);
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_ChartSparklinePainter oldDelegate) =>
      oldDelegate.color != color || !listEquals(oldDelegate.values, values);
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
    final Widget cover = RepaintBoundary(child: stillCover);
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
  _SearchTab _tab = _SearchTab.songs;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(inset, 0, inset, 10),
          child: Row(
            children: <Widget>[
              _SearchTabButton(
                label: '歌曲',
                active: _tab == _SearchTab.songs,
                onTap: () => setState(() => _tab = _SearchTab.songs),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '专辑',
                active: _tab == _SearchTab.albums,
                onTap: () => setState(() => _tab = _SearchTab.albums),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '歌手',
                active: _tab == _SearchTab.artists,
                onTap: () => setState(() => _tab = _SearchTab.artists),
              ),
              const SizedBox(width: 8),
              _SearchTabButton(
                label: '歌单',
                active: _tab == _SearchTab.playlists,
                onTap: () => setState(() => _tab = _SearchTab.playlists),
              ),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            _SearchTab.songs => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (int i = 0; i < results.tracks.length; i++)
                  LegacyTrackRow(
                    track: results.tracks[i],
                    index: i,
                    current: widget.state.current?.id == results.tracks[i].id,
                    playing: widget.state.playing,
                    onTap: () =>
                        widget.state.playQueue(results.tracks, startIndex: i),
                  ),
              ],
            ),
            _SearchTab.albums => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (final Album album in results.albums)
                  AppleListTile(
                    title: album.title,
                    subtitle: album.artist,
                    minHeight: 56,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    leading: LegacyCover(
                      url: album.coverUrl,
                      size: 44,
                      radius: 6,
                    ),
                    onTap: () => unawaited(
                      openAlbumDetails(context, widget.state, album),
                    ),
                  ),
              ],
            ),
            _SearchTab.artists => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                for (final ArtistRef artist in results.artists)
                  AppleListTile(
                    title: artist.name,
                    subtitle: '歌手',
                    minHeight: 56,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    leading: ClipOval(
                      child: LegacyCover(
                        url: artist.coverUrl,
                        size: 44,
                        radius: 22,
                      ),
                    ),
                    onTap: () => artistDetailRequest.value = artist,
                  ),
              ],
            ),
            _SearchTab.playlists => ListView(
              padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
              children: <Widget>[
                LegacyPlaylistGrid(
                  playlists: results.playlists,
                  onOpen: widget.onOpenPlaylist,
                ),
              ],
            ),
          },
        ),
      ],
    );
  }
}

/// Tabs across the top of the search results.
enum _SearchTab { songs, albums, artists, playlists }

class _SearchTabButton extends StatelessWidget {
  const _SearchTabButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Semantics(
      button: true,
      selected: active,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: active ? apple.label.withValues(alpha: .1) : null,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: active ? apple.label : apple.secondaryLabel,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
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
                  if (defaultTargetPlatform == TargetPlatform.iOS ||
                      defaultTargetPlatform == TargetPlatform.android)
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
