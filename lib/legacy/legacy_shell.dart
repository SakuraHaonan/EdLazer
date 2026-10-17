import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import 'legacy_login.dart';
import 'legacy_now_playing.dart';
import 'legacy_pages.dart';
import 'legacy_theme.dart';
import 'legacy_widgets.dart';

/// The legacy shell, ported from the Lazer project (`E:\projects\Lazer`,
/// `desktopApp/.../DesktopPlayerApp.kt` and `shared/.../LazerApp.kt`): a
/// Material 3 rail on the left, a search field on top, the content page in the
/// middle and the transport bar along the bottom.
class LegacyShell extends StatefulWidget {
  const LegacyShell({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyShell> createState() => _LegacyShellState();
}

enum _LegacySection { home, library, likes, settings }

class _LegacyShellState extends State<LegacyShell> {
  _LegacySection _section = _LegacySection.home;
  Playlist? _playlist;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  Timer? _searchDebounce;

  AppState get state => widget.state;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
    });
  }

  void _select(_LegacySection section) {
    setState(() {
      _section = section;
      _playlist = null;
      if (section != _LegacySection.settings) _query = '';
      if (_query.isEmpty && _search.text.isNotEmpty) _search.clear();
    });
  }

  void _openPlaylist(Playlist playlist) {
    setState(() {
      _playlist = playlist;
      _query = '';
      _search.clear();
    });
  }

  void _openNowPlaying() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              LegacyNowPlayingPage(state: state),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final Size window = MediaQuery.sizeOf(context);
        final bool wide = window.width >= 760;
        // The full transport needs room for five controls plus the progress
        // row; below this the bar folds to the compact form even while the
        // rail is still on screen.
        final bool compactBar = window.width < 1_000;
        return Scaffold(
          backgroundColor: scheme.surface,
          body: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    if (wide) _rail(scheme),
                    Expanded(
                      child: Column(
                        children: [
                          _topBar(context, scheme, wide),
                          Expanded(child: _content()),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              _LegacyPlayerBar(
                state: state,
                compact: compactBar,
                onOpen: _openNowPlaying,
              ),
              if (!wide)
                NavigationBar(
                  selectedIndex: _section.index,
                  onDestinationSelected: (int index) =>
                      _select(_LegacySection.values[index]),
                  destinations: const <NavigationDestination>[
                    NavigationDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home_rounded),
                      label: '主页',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.library_music_outlined),
                      selectedIcon: Icon(Icons.library_music_rounded),
                      label: '音乐库',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.favorite_border_rounded),
                      selectedIcon: Icon(Icons.favorite_rounded),
                      label: '我喜欢',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings_rounded),
                      label: '设置',
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  // -- chrome ---------------------------------------------------------------

  Widget _rail(ColorScheme scheme) {
    return Container(
      width: LegacyTokens.railWidth,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.graphic_eq_rounded,
                    size: 22,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Text('Lazer', style: Theme.of(context).textTheme.headlineSmall),
              ],
            ),
          ),
          LegacyRailItem(
            icon: Icons.home_outlined,
            label: '主页',
            selected: _section == _LegacySection.home && _playlist == null,
            onTap: () => _select(_LegacySection.home),
          ),
          const SizedBox(height: 2),
          LegacyRailItem(
            icon: Icons.library_music_outlined,
            label: '音乐库',
            selected: _section == _LegacySection.library,
            onTap: () => _select(_LegacySection.library),
          ),
          const SizedBox(height: 2),
          LegacyRailItem(
            icon: Icons.favorite_border_rounded,
            label: '我喜欢',
            selected: _section == _LegacySection.likes,
            onTap: () => _select(_LegacySection.likes),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Divider(height: 1),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '你的歌单',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (state.signedIn)
                  IconButton(
                    tooltip: '刷新歌单',
                    iconSize: 18,
                    onPressed: () =>
                        unawaited(state.refreshCollections(force: true)),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
              ],
            ),
          ),
          Expanded(child: _railPlaylists(scheme)),
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
            child: LegacyRailItem(
              icon: Icons.settings_outlined,
              label: '设置',
              selected: _section == _LegacySection.settings,
              onTap: () => _select(_LegacySection.settings),
            ),
          ),
        ],
      ),
    );
  }

  Widget _railPlaylists(ColorScheme scheme) {
    final List<Playlist> playlists = <Playlist>[
      if (state.collections.liked != null) state.collections.liked!,
      ...state.collections.created,
      ...state.collections.subscribed,
    ];
    if (playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
        child: Text(
          state.isGuest ? '登录后同步你的歌单' : '暂无歌单',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final Playlist playlist = playlists[index];
        final bool selected = _playlist?.id == playlist.id;
        return _RailPlaylist(
          playlist: playlist,
          selected: selected,
          onTap: () => _openPlaylist(playlist),
        );
      },
    );
  }

  Widget _topBar(BuildContext context, ColorScheme scheme, bool wide) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 28 : 16, wide ? 14 : 10, 20, 12),
      child: Row(
        children: [
          if (_playlist != null) ...[
            IconButton(
              tooltip: '返回',
              onPressed: () => setState(() => _playlist = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 20),
            ),
            const SizedBox(width: 4),
          ],
          if (!wide) ...[
            Icon(Icons.graphic_eq_rounded, color: scheme.primary, size: 22),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: SizedBox(
              height: 46,
              child: TextField(
                controller: _search,
                onChanged: _onQueryChanged,
                textInputAction: TextInputAction.search,
                style: theme.textTheme.bodyMedium,
                decoration: InputDecoration(
                  hintText: '搜索…',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除',
                          iconSize: 18,
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 4),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip: theme.brightness == Brightness.dark ? '浅色' : '深色',
            onPressed: () => unawaited(
              state.setThemeMode(
                theme.brightness == Brightness.dark
                    ? ThemeMode.light
                    : ThemeMode.dark,
              ),
            ),
            icon: Icon(
              theme.brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              size: 20,
            ),
          ),
          const SizedBox(width: 4),
          _accountButton(scheme),
        ],
      ),
    );
  }

  Widget _accountButton(ColorScheme scheme) {
    final String initial = state.isGuest
        ? '游'
        : state.user.name.characters.first;
    return PopupMenuButton<String>(
      tooltip: state.isGuest ? '登录' : state.user.name,
      offset: const Offset(0, 46),
      onSelected: (String value) {
        if (value == 'login') {
          unawaited(showLegacyLoginDialog(context, state));
        } else if (value == 'logout') {
          state.signOut();
        } else if (value == 'settings') {
          _select(_LegacySection.settings);
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'header',
          enabled: false,
          child: Text(
            state.isGuest ? '游客模式' : '${state.user.name} · ${state.user.detail}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (state.isGuest)
          const PopupMenuItem<String>(value: 'login', child: Text('登录'))
        else
          const PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
        const PopupMenuItem<String>(value: 'settings', child: Text('设置')),
      ],
      child: CircleAvatar(
        radius: 19,
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: Text(initial, style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Widget _content() {
    if (_query.isNotEmpty) {
      return LegacySearchPage(
        state: state,
        query: _query,
        onOpenPlaylist: _openPlaylist,
      );
    }
    final Playlist? playlist = _playlist;
    if (playlist != null) {
      return LegacyPlaylistPage(state: state, playlist: playlist);
    }
    return switch (_section) {
      _LegacySection.home => LegacyHomePage(
        state: state,
        onOpenPlaylist: _openPlaylist,
        onPlayTrack: (List<Track> tracks, int index) =>
            state.playQueue(tracks, startIndex: index),
      ),
      _LegacySection.library => LegacyLibraryPage(
        state: state,
        onOpenPlaylist: _openPlaylist,
      ),
      _LegacySection.likes => LegacyLikesPage(state: state),
      _LegacySection.settings => LegacySettingsPage(state: state),
    };
  }
}

class _RailPlaylist extends StatefulWidget {
  const _RailPlaylist({
    required this.playlist,
    required this.selected,
    required this.onTap,
  });

  final Playlist playlist;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_RailPlaylist> createState() => _RailPlaylistState();
}

class _RailPlaylistState extends State<_RailPlaylist> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: widget.selected
                ? scheme.secondaryContainer
                : _hovering
                ? scheme.onSurface.withValues(alpha: 0.05)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              LegacyCover(url: widget.playlist.coverUrl, size: 34, radius: 8, iconSize: 14),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The bottom transport bar: cover and title on the left, transport and
/// progress in the middle, volume and queue on the right.
class _LegacyPlayerBar extends StatelessWidget {
  const _LegacyPlayerBar({
    required this.state,
    required this.compact,
    required this.onOpen,
  });

  final AppState state;
  final bool compact;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AnimatedBuilder(
      animation: state,
      builder: (BuildContext context, _) {
        final Track? track = state.current;
        final Widget leading = InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(12),
          child: Row(
            children: [
              LegacyCover(url: track?.coverUrl, size: compact ? 44 : 52, radius: 10),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: compact ? 130 : 180,
                    child: Text(
                      track?.title ?? '未选择曲目',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    width: compact ? 130 : 180,
                    child: Text(
                      track?.artist ?? 'Lazer',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
        return Container(
          height: compact
              ? LegacyTokens.compactPlayerBarHeight
              : LegacyTokens.playerBarHeight,
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(top: BorderSide(color: scheme.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: compact
              ? Row(
                  children: [
                    Expanded(child: leading),
                    IconButton(
                      tooltip: state.playing ? '暂停' : '播放',
                      onPressed: state.togglePlay,
                      icon: Icon(
                        state.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 28,
                      ),
                    ),
                    IconButton(
                      tooltip: '下一首',
                      onPressed: state.next,
                      icon: const Icon(Icons.skip_next_rounded, size: 26),
                    ),
                    IconButton(
                      tooltip: '播放队列',
                      onPressed: () => _showQueue(context),
                      icon: const Icon(Icons.queue_music_rounded, size: 22),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: leading)),
                    IconButton(
                      tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
                      onPressed: state.current == null
                          ? null
                          : () => unawaited(state.toggleLikeCurrent()),
                      icon: Icon(
                        state.currentLiked
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        size: 20,
                        color: state.currentLiked
                            ? scheme.tertiary
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      flex: 5,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          LegacyTransportControls(state: state),
                          const SizedBox(height: 2),
                          LegacyProgressBar(state: state),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            tooltip: state.volume > 0 ? '静音' : '取消静音',
                            onPressed: () => unawaited(state.toggleMute()),
                            icon: Icon(
                              state.volume <= 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 20,
                            ),
                          ),
                          SizedBox(
                            width: 96,
                            child: Slider(
                              value: state.volume.clamp(0, 1),
                              onChanged: (double value) =>
                                  unawaited(state.setVolume(value)),
                            ),
                          ),
                          IconButton(
                            tooltip: '播放队列',
                            onPressed: () => _showQueue(context),
                            icon: const Icon(
                              Icons.queue_music_rounded,
                              size: 20,
                            ),
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

  void _showQueue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) => _LegacyQueueSheet(state: state),
    );
  }
}

class _LegacyQueueSheet extends StatelessWidget {
  const _LegacyQueueSheet({required this.state});

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
                  Text('播放队列 · ${state.queue.length} 首', style: theme.textTheme.titleMedium),
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
