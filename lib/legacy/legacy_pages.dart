import 'dart:async';

import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../l10n/app_language.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import 'legacy_login.dart';
import 'legacy_theme.dart';
import 'legacy_widgets.dart';

/// Scroll padding shared by every legacy page.
const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(
  LegacyTokens.pagePadding,
  4,
  LegacyTokens.pagePadding,
  40,
);

/// `今天为你整理` — the discovery page: a rail of recommended playlists and the
/// quick-pick track list, as the Lazer home screen lays it out.
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
    final ThemeData theme = Theme.of(context);
    final HomeFeed? feed = state.home;
    if (feed == null) {
      return LegacyNotice(
        message: state.homeError ?? '正在加载曲库…',
        action: state.homeError == null
            ? null
            : FilledButton.tonal(
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
    return ListView(
      padding: _pagePadding,
      children: [
        if (rail.isNotEmpty) ...[
          const LegacySectionHeader(
            title: '今天为你整理',
            subtitle: '来自你的听歌偏好',
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 250,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: rail.length,
              separatorBuilder: (_, _) => const SizedBox(width: 18),
              itemBuilder: (BuildContext context, int index) => LegacyPlaylistCard(
                playlist: rail[index],
                onTap: () => onOpenPlaylist(rail[index]),
              ),
            ),
          ),
          const SizedBox(height: 30),
        ],
        LegacySectionHeader(
          title: likedName ?? '为你推荐',
          subtitle: tracks.isEmpty ? null : '${tracks.length} 首',
        ),
        const SizedBox(height: 10),
        if (tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              '曲库还没有返回可播放的曲目。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (int i = 0; i < tracks.length; i++)
            LegacyTrackRow(
              track: tracks[i],
              index: i,
              current: state.current?.id == tracks[i].id,
              playing: state.playing,
              onTap: () => onPlayTrack(tracks, i),
            ),
      ],
    );
  }
}

/// `音乐库` — the signed-in collections and the public recommended playlists.
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
                onPressed: () => unawaited(showLegacyLoginDialog(context, state)),
                child: const Text('登录'),
              )
            : null,
      );
    }
    return ListView(
      padding: _pagePadding,
      children: [
        if (mine.isNotEmpty) ...[
          LegacySectionHeader(
            title: '我的音乐',
            subtitle: state.isGuest ? '游客模式' : state.user.name,
            trailing: state.signedIn
                ? IconButton(
                    tooltip: '刷新歌单',
                    onPressed: () =>
                        unawaited(state.refreshCollections(force: true)),
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  )
                : null,
          ),
          const SizedBox(height: 16),
          LegacyPlaylistGrid(playlists: mine, onOpen: onOpenPlaylist),
          const SizedBox(height: 32),
        ],
        if (publicLists.isNotEmpty) ...[
          const LegacySectionHeader(title: '推荐歌单'),
          const SizedBox(height: 16),
          LegacyPlaylistGrid(playlists: publicLists, onOpen: onOpenPlaylist),
        ],
      ],
    );
  }
}

/// `我喜欢` — the liked-songs playlist.
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
      return const LegacyNotice(message: '正在读取喜欢的音乐…');
    }
    return LegacyPlaylistPage(state: state, playlist: liked, embedded: true);
  }
}

/// One playlist: header with cover and play-all, then its tracks.
class LegacyPlaylistPage extends StatefulWidget {
  const LegacyPlaylistPage({
    super.key,
    required this.state,
    required this.playlist,
    this.embedded = false,
  });

  final AppState state;
  final Playlist playlist;
  final bool embedded;

  @override
  State<LegacyPlaylistPage> createState() => _LegacyPlaylistPageState();
}

class _LegacyPlaylistPageState extends State<LegacyPlaylistPage> {
  List<Track>? _tracks;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final List<Track> tracks = await widget.state.catalog.playlistTracks(
        widget.playlist.id,
      );
      if (!mounted) return;
      setState(() => _tracks = tracks);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '歌单读取失败，请重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<Track>? tracks = _tracks;
    return ListView(
      padding: _pagePadding,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            LegacyCover(url: widget.playlist.coverUrl, size: 160, radius: 20),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.playlist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    <String>[
                      if (widget.playlist.trackCount > 0)
                        '${widget.playlist.trackCount} 首',
                      if (widget.playlist.description.isNotEmpty)
                        widget.playlist.description,
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: tracks == null || tracks.isEmpty
                        ? null
                        : () => widget.state.playQueue(tracks),
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: const Text('播放全部'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (_error != null)
          LegacyNotice(
            message: _error!,
            action: FilledButton.tonal(
              onPressed: () => unawaited(_load()),
              child: const Text('重试'),
            ),
          )
        else if (tracks == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (tracks.isEmpty)
          const LegacyNotice(message: '这个歌单还没有可播放的曲目。')
        else
          for (int i = 0; i < tracks.length; i++)
            LegacyTrackRow(
              track: tracks[i],
              index: i,
              current: widget.state.current?.id == tracks[i].id,
              playing: widget.state.playing,
              onTap: () => widget.state.playQueue(tracks, startIndex: i),
            ),
      ],
    );
  }
}

/// Search results for the top bar query.
class LegacySearchPage extends StatefulWidget {
  const LegacySearchPage({
    super.key,
    required this.state,
    required this.query,
    required this.onOpenPlaylist,
  });

  final AppState state;
  final String query;
  final ValueChanged<Playlist> onOpenPlaylist;

  @override
  State<LegacySearchPage> createState() => _LegacySearchPageState();
}

class _LegacySearchPageState extends State<LegacySearchPage> {
  SearchResults? _results;
  bool _loading = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  @override
  void didUpdateWidget(covariant LegacySearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) unawaited(_run());
  }

  Future<void> _run() async {
    final int generation = ++_generation;
    final String query = widget.query.trim();
    if (query.isEmpty) {
      setState(() {
        _results = null;
        _loading = false;
      });
      return;
    }
    setState(() {
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
    final ThemeData theme = Theme.of(context);
    final SearchResults? results = _results;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LegacyNotice(
        message: _error!,
        icon: Icons.search_off_rounded,
        action: FilledButton.tonal(
          onPressed: () => unawaited(_run()),
          child: const Text('重试'),
        ),
      );
    }
    if (results == null || results.hits == 0) {
      return const LegacyNotice(message: '没有找到相关结果。', icon: Icons.search_rounded);
    }
    return ListView(
      padding: _pagePadding,
      children: [
        if (results.tracks.isNotEmpty) ...[
          LegacySectionHeader(title: '单曲', subtitle: '${results.tracks.length} 首'),
          const SizedBox(height: 10),
          for (int i = 0; i < results.tracks.length; i++)
            LegacyTrackRow(
              track: results.tracks[i],
              index: i,
              current: widget.state.current?.id == results.tracks[i].id,
              playing: widget.state.playing,
              onTap: () => widget.state.playQueue(results.tracks, startIndex: i),
            ),
          const SizedBox(height: 28),
        ],
        if (results.playlists.isNotEmpty) ...[
          const LegacySectionHeader(title: '歌单'),
          const SizedBox(height: 16),
          LegacyPlaylistGrid(
            playlists: results.playlists,
            onOpen: widget.onOpenPlaylist,
          ),
          const SizedBox(height: 28),
        ],
        if (results.albums.isNotEmpty) ...[
          const LegacySectionHeader(title: '专辑'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 18,
            children: [
              for (final Album album in results.albums)
                SizedBox(
                  width: 160,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LegacyCover(url: album.coverUrl, size: 160, radius: 16),
                      const SizedBox(height: 8),
                      Text(
                        album.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      Text(
                        album.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// `设置` for the legacy shell: the interface switch, appearance, language and
/// the account, laid out as the legacy settings rows.
class LegacySettingsPage extends StatelessWidget {
  const LegacySettingsPage({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return ListView(
      padding: _pagePadding,
      children: [
        Text('设置', style: theme.textTheme.displaySmall),
        const SizedBox(height: 6),
        Text(
          '外观、界面和账户。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 26),
        const _LegacySectionLabel('界面'),
        _LegacySettingRow(
          label: '界面风格',
          subtitle: state.uiStyle.detail,
          trailing: SegmentedButton<AppUiStyle>(
            showSelectedIcon: false,
            segments: <ButtonSegment<AppUiStyle>>[
              for (final AppUiStyle style in AppUiStyle.values)
                ButtonSegment<AppUiStyle>(
                  value: style,
                  label: Text(style.label),
                ),
            ],
            selected: <AppUiStyle>{state.uiStyle},
            onSelectionChanged: (Set<AppUiStyle> selection) =>
                unawaited(state.setUiStyle(selection.first)),
          ),
        ),
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
            borderRadius: BorderRadius.circular(16),
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
              if (value != null) unawaited(state.setThemeMode(value));
            },
          ),
        ),
        _LegacySettingRow(
          label: '语言',
          subtitle: state.language.name,
          trailing: DropdownButton<AppLanguage>(
            value: state.language,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(16),
            items: <DropdownMenuItem<AppLanguage>>[
              for (final AppLanguage language in AppLanguage.values)
                DropdownMenuItem<AppLanguage>(
                  value: language,
                  child: Text(language.name),
                ),
            ],
            onChanged: (AppLanguage? value) {
              if (value != null) unawaited(state.setLanguage(value));
            },
          ),
        ),
        const _LegacySectionLabel('账户'),
        _LegacySettingRow(
          label: state.isGuest ? '游客' : state.user.name,
          subtitle: state.isGuest
              ? '登录后同步歌单和每日推荐'
              : '${state.user.methodLabel} · ${state.user.detail}',
          trailing: state.isGuest
              ? FilledButton(
                  onPressed: () =>
                      unawaited(showLegacyLoginDialog(context, state)),
                  child: const Text('登录'),
                )
              : TextButton(
                  onPressed: state.signOut,
                  child: const Text('退出登录'),
                ),
        ),
        const _LegacySectionLabel('关于'),
        _LegacySettingRow(
          label: 'Legacy UI',
          subtitle: '移植自 Lazer 项目：Material 3 蓝色夜间配色、左侧导航与播放条',
          trailing: Text(
            'Lazer',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _LegacySectionLabel extends StatelessWidget {
  const _LegacySectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 18, 2, 6),
      child: Text(
        label,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
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
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Flexible(child: trailing),
        ],
      ),
    );
  }
}

/// The legacy library grid: cards sized to the available width.
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
        final int columns = (width / 196).floor().clamp(2, 8);
        final double gap = 18;
        final double cell = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: 24,
          children: [
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
