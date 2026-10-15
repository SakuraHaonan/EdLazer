import 'package:lazer_nextgen/theme/app_palette.dart';
import '../l10n/app_localizations.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/paper_widgets.dart';
import '../widgets/plate_art.dart';
import '../widgets/accessible_controls.dart';
import 'now_playing_page.dart';
import 'player_page.dart';

class PlaylistDetailPage extends StatelessWidget {
  const PlaylistDetailPage({
    super.key,
    required this.playlist,
    required this.state,
  });
  final Playlist playlist;
  final AppState state;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const TrText('歌单')),
    body: Column(
      children: [
        Expanded(
          child: PlaylistDetailView(playlist: playlist, state: state),
        ),
        PlayerControlsBar(
          state: state,
          includeBottomSafeArea: true,
          onExpand: () => unawaited(
            Navigator.of(context).push(NowPlayingRoute(state: state)),
          ),
        ),
      ],
    ),
  );
}

/// Desktop embeds this view in the shell, retaining the sidebar and transport.
class PlaylistDetailView extends StatefulWidget {
  const PlaylistDetailView({
    super.key,
    required this.playlist,
    required this.state,
    this.onBack,
  });
  final Playlist playlist;
  final AppState state;
  final VoidCallback? onBack;
  @override
  State<PlaylistDetailView> createState() => _PlaylistDetailViewState();
}

class _PlaylistDetailViewState extends State<PlaylistDetailView> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _headerKey = GlobalKey();
  final GlobalKey _tableKey = GlobalKey();
  final ValueNotifier<bool> _showLocator = ValueNotifier(false);
  List<Track> _loadedTracks = [];
  double _headerExtent = 0;
  double _tableExtent = 0;
  bool _geometryPending = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrolled);
    widget.state.addListener(_updateLocator);
  }

  void _scrolled() {
    _updateLocator();
    _measureGeometry();
  }

  void _measureGeometry() {
    if (_geometryPending) return;
    _geometryPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryPending = false;
      if (!mounted) return;
      _headerExtent = _headerKey.currentContext?.size?.height ?? _headerExtent;
      _tableExtent = _tableKey.currentContext?.size?.height ?? _tableExtent;
      _updateLocator();
    });
  }

  double _trackTop(int index) =>
      _headerExtent +
      _tableExtent +
      _loadedTracks
          .take(index)
          .fold(0.0, (height, track) => height + _rowHeight(track));

  void _updateLocator() {
    if (!mounted || !_scroll.hasClients) return;
    final index = _loadedTracks.indexWhere(
      (track) => track.id == widget.state.current?.id,
    );
    if (index < 0) {
      _showLocator.value = false;
      return;
    }
    final top = _trackTop(index);
    final bottom = top + _rowHeight(_loadedTracks[index]);
    final position = _scroll.position;
    final visible =
        bottom > position.pixels &&
        top < position.pixels + position.viewportDimension;
    _showLocator.value = !visible;
  }

  late Future<List<Track>> _tracks = widget.state.catalog.playlistTracks(
    widget.playlist.id,
  );
  bool _expanded = false;
  void _refresh() {
    setState(() {
      _tracks = widget.state.catalog.refreshPlaylist(widget.playlist.id);
    });
  }

  TextScaler? _rowScaler;
  double _normalRowHeight = 64;
  double _translatedRowHeight = 80;
  @override
  void dispose() {
    widget.state.removeListener(_updateLocator);
    _scroll.dispose();
    _showLocator.dispose();
    super.dispose();
  }

  double _rowHeight(Track track) {
    final scaler = MediaQuery.textScalerOf(context);
    if (scaler == _rowScaler) {
      return (track.translatedTitle?.isNotEmpty ?? false)
          ? _translatedRowHeight
          : _normalRowHeight;
    }
    double lineHeight(TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: '歌曲', style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

    final title = lineHeight(
      context.type.body.copyWith(fontSize: 16, height: 1.3),
    );
    final caption = lineHeight(context.type.captionMuted);
    _normalRowHeight = ((title + caption) > 40 ? title + caption : 40) + 24;
    _translatedRowHeight =
        ((title + caption * 2) > 40 ? title + caption * 2 : 40) + 24;
    _rowScaler = scaler;
    return (track.translatedTitle?.isNotEmpty ?? false)
        ? _translatedRowHeight
        : _normalRowHeight;
  }

  void _locateCurrent(List<Track> tracks) {
    final id = widget.state.current?.id;
    final index = tracks.indexWhere((track) => track.id == id);
    if (index < 0) return;
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      (_trackTop(index) - _scroll.position.viewportDimension * 0.35).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(covariant PlaylistDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_updateLocator);
      widget.state.addListener(_updateLocator);
    }
    if (oldWidget.playlist.id != widget.playlist.id) {
      _tracks = widget.state.catalog.playlistTracks(widget.playlist.id);
      _expanded = false;
      _loadedTracks = [];
      _headerExtent = 0;
      _tableExtent = 0;
      _showLocator.value = false;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final desktop = widget.onBack != null;
      final horizontal = desktop ? 32.0 : 24.0;
      return FutureBuilder<List<Track>>(
        future: _tracks,
        builder: (context, snapshot) {
          final tracks = snapshot.data ?? <Track>[];
          _loadedTracks = snapshot.connectionState == ConnectionState.done
              ? tracks
              : [];
          if (!desktop || box.maxWidth <= 600) _tableExtent = 0;
          _measureGeometry();
          final playlist = widget.playlist;
          return Stack(
            children: [
              CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      key: _headerKey,
                      padding: EdgeInsets.fromLTRB(
                        horizontal,
                        20,
                        horizontal,
                        24,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.onBack != null) ...[
                            TextButton.icon(
                              onPressed: widget.onBack,
                              icon: const Icon(
                                Icons.arrow_back_rounded,
                                size: 18,
                              ),
                              label: const TrText('返回'),
                              style: TextButton.styleFrom(
                                foregroundColor: context.colors.slateDark,
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox.square(
                                dimension: box.maxWidth < 600 ? 100 : 152,
                                child: PlateArt(
                                  seed: playlist.coverSeed,
                                  coverUrl: playlist.coverUrl,
                                ),
                              ),
                              const SizedBox(width: 24),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const InlineLabel('歌单'),
                                    const SizedBox(height: 8),
                                    Text(
                                      playlist.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.type.subheading.copyWith(
                                        fontSize: desktop ? 28 : 23,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    TrText(
                                      '${snapshot.hasData ? tracks.length : playlist.trackCount} 首',
                                      style: context.type.captionMuted,
                                    ),
                                    const SizedBox(height: 16),
                                    Wrap(
                                      spacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        ClayButton(
                                          label: '播放全部',
                                          compact: true,
                                          onPressed: tracks.isEmpty
                                              ? null
                                              : () => widget.state.playQueue(
                                                  tracks,
                                                ),
                                        ),
                                        AccessibleIconButton(
                                          tooltip: '刷新歌单',
                                          onPressed:
                                              snapshot.connectionState ==
                                                  ConnectionState.waiting
                                              ? null
                                              : _refresh,
                                          icon: const Icon(
                                            Icons.refresh_rounded,
                                            size: 20,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (playlist.description.isNotEmpty) ...[
                            const SizedBox(height: 20),
                            AnimatedSize(
                              duration: const Duration(milliseconds: 220),
                              alignment: Alignment.topLeft,
                              child: Text(
                                playlist.description,
                                maxLines: _expanded ? null : 2,
                                overflow: _expanded
                                    ? null
                                    : TextOverflow.ellipsis,
                                style: context.type.body.copyWith(
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () =>
                                  setState(() => _expanded = !_expanded),
                              style: TextButton.styleFrom(
                                foregroundColor: context.colors.cloudDark,
                              ),
                              child: TrText(_expanded ? '收起简介' : '展开简介'),
                            ),
                          ],
                          if (snapshot.hasError) ...[
                            const SizedBox(height: 20),
                            const TrText('歌单加载失败，请重试。'),
                            TextButton(
                              onPressed: _refresh,
                              child: const TrText('重新加载'),
                            ),
                          ] else if (!snapshot.hasData) ...[
                            const SizedBox(height: 20),
                            const LinearProgressIndicator(),
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (desktop && box.maxWidth > 600)
                    SliverToBoxAdapter(
                      child: Padding(
                        key: _tableKey,
                        padding: EdgeInsets.symmetric(
                          horizontal: horizontal + 24,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 88),
                            Expanded(
                              flex: 3,
                              child: TrText(
                                '歌曲 / 歌手',
                                style: context.type.captionMuted,
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: TrText(
                                '专辑',
                                style: context.type.captionMuted,
                              ),
                            ),
                            TrText('时长', style: context.type.captionMuted),
                          ],
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: horizontal),
                    sliver: SliverVariedExtentList.builder(
                      itemCount: tracks.length,
                      itemExtentBuilder: (index, _) =>
                          _rowHeight(tracks[index]),
                      itemBuilder: (context, index) => AnimatedBuilder(
                        animation: widget.state,
                        builder: (context, _) => TrackRow(
                          track: tracks[index],
                          index: index + 1,
                          isCurrent:
                              widget.state.current?.id == tracks[index].id,
                          onPlay: () =>
                              widget.state.playQueue(tracks, startIndex: index),
                        ),
                      ),
                    ),
                  ),
                  if (snapshot.hasData && tracks.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: TrText('歌单里还没有歌曲。'),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
              Positioned(
                right: 24,
                bottom: 24,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _showLocator,
                  builder: (context, visible, child) => IgnorePointer(
                    ignoring: !visible,
                    child: AnimatedScale(
                      scale: visible ? 1 : .7,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: visible ? 1 : 0,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: ExcludeSemantics(
                          excluding: !visible,
                          child: child!,
                        ),
                      ),
                    ),
                  ),
                  child: AccessibleTooltip(
                    message: '定位正在播放的歌曲',
                    child: FloatingActionButton(
                      heroTag: null,
                      elevation: 0,
                      hoverElevation: 0,
                      focusElevation: 0,
                      highlightElevation: 0,
                      shape: const CircleBorder(),
                      backgroundColor: context.colors.slateDark,
                      foregroundColor: context.colors.onDark,
                      onPressed: () => _locateCurrent(tracks),
                      child: const Icon(Icons.my_location_rounded),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
