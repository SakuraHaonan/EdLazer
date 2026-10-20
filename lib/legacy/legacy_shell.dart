import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../widgets/song_comments_view.dart';
import 'legacy_background.dart';
import 'legacy_login.dart';
import 'legacy_now_playing.dart';
import 'legacy_pages.dart';
import 'legacy_player_bar.dart';
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
  bool _comments = false;
  SongCommentsController? _commentsController;

  AppState get state => widget.state;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _commentsController?.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _query = value.trim();
        if (_query.isNotEmpty) _comments = false;
      });
    });
  }

  void _select(_LegacySection section) {
    setState(() {
      _section = section;
      _playlist = null;
      _comments = false;
      if (section != _LegacySection.settings) _query = '';
      if (_query.isEmpty && _search.text.isNotEmpty) _search.clear();
    });
  }

  void _openPlaylist(Playlist playlist) {
    setState(() {
      _playlist = playlist;
      _comments = false;
      _query = '';
      _search.clear();
    });
  }

  void _toggleComments() {
    setState(() {
      _comments = !_comments;
      if (_comments) {
        _commentsController ??= SongCommentsController(state.gateway);
      }
    });
  }

  void _openNowPlaying() {
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/legacy-now-playing'),
          builder: (BuildContext context) => LegacyNowPlayingPage(state: state),
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
        final bool hasBackground =
            state.legacyBackground != LegacyBackgroundMode.off;
        final bool needsSeed =
            state.legacyPalette == LegacyPaletteMode.nowPlaying;
        return Scaffold(
          backgroundColor: hasBackground
              ? Colors.transparent
              : legacyPageBackgroundOf(scheme),
          body: Stack(
            fit: StackFit.expand,
            children: [
              // The album-coloured canvas the Lazer app floats its chrome over.
              if (hasBackground || needsSeed)
                LegacyAlbumBackdrop(
                  track: state.current,
                  mode: hasBackground
                      ? state.legacyBackground
                      : LegacyBackgroundMode.off,
                  uiAlpha: state.legacyUiAlpha,
                  onSeed: state.setLegacySeed,
                ),
              // The canvas above stays full-bleed; the chrome column starts
              // below the status bar or notch. The bottom is left to the
              // chrome itself: the NavigationBar consumes the bottom safe
              // area on its own, and on the desktop the bar has none.
              SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          if (wide)
                            RepaintBoundary(
                              child: _rail(scheme, hasBackground),
                            ),
                          Expanded(
                            child: Column(
                              children: [
                                // The legacy comments page replaces the whole
                                // content column, search bar included.
                                if (!_comments) _topBar(context, scheme, wide),
                                Expanded(
                                  child: RepaintBoundary(child: _content()),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    LegacyPlayerBar(
                      state: state,
                      compact: compactBar,
                      comments: _comments,
                      onComments: _toggleComments,
                      onOpen: _openNowPlaying,
                    ),
                    if (!wide)
                      NavigationBar(
                        backgroundColor: hasBackground
                            ? scheme.surface.withValues(alpha: 0.78)
                            : null,
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
              ),
            ],
          ),
        );
      },
    );
  }

  // -- chrome ---------------------------------------------------------------

  Widget _rail(ColorScheme scheme, bool translucent) {
    final double uiAlpha = state.legacyBackground == LegacyBackgroundMode.off
        ? 1
        : state.legacyUiAlpha;
    return Container(
      width: LegacyTokens.railWidth,
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.86 * uiAlpha),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 0),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.library_music_rounded,
                    size: 23,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Text('Lazer', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LegacyRailItem(
                  icon: Icons.home_outlined,
                  label: '主页',
                  selected:
                      _section == _LegacySection.home && _playlist == null,
                  onTap: () => _select(_LegacySection.home),
                ),
                const SizedBox(height: 4),
                LegacyRailItem(
                  icon: Icons.library_music_outlined,
                  label: '音乐库',
                  selected: _section == _LegacySection.library,
                  onTap: () => _select(_LegacySection.library),
                ),
                const SizedBox(height: 4),
                LegacyRailItem(
                  icon: Icons.favorite_border_rounded,
                  label: '我喜欢',
                  selected: _section == _LegacySection.likes,
                  onTap: () => _select(_LegacySection.likes),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '你的歌单',
                    style: Theme.of(
                      context,
                    ).textTheme.titleSmall?.copyWith(color: scheme.onSurface),
                  ),
                ),
                if (state.signedIn)
                  SizedBox.square(
                    dimension: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      iconSize: 16,
                      visualDensity: VisualDensity.compact,
                      tooltip: '同步歌单',
                      onPressed: () =>
                          unawaited(state.refreshCollections(force: true)),
                      icon: Icon(Icons.sync_rounded, color: scheme.primary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: _railPlaylists(scheme),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: LegacyRailItem(
              icon: Icons.settings_outlined,
              label: '设置',
              selected: _section == _LegacySection.settings,
              onTap: () => _select(_LegacySection.settings),
            ),
          ),
          const SizedBox(height: 18),
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
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Text(
          state.isGuest ? '登录后同步你的歌单' : '暂无歌单',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: playlists.length,
      itemBuilder: (BuildContext context, int index) {
        final Playlist playlist = playlists[index];
        return _RailPlaylist(
          playlist: playlist,
          selected: _playlist?.id == playlist.id,
          onTap: () => _openPlaylist(playlist),
        );
      },
    );
  }

  Widget _topBar(BuildContext context, ColorScheme scheme, bool wide) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(28, wide ? 16 : 12, 28, 10),
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
            Icon(Icons.library_music_rounded, color: scheme.primary, size: 22),
            const SizedBox(width: 10),
          ],
          Expanded(
            flex: 100,
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: _searchField(theme, scheme),
              ),
            ),
          ),
          const Spacer(flex: 18),
          _barIconButton(
            scheme: scheme,
            icon: theme.brightness == Brightness.dark
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined,
            tooltip: theme.brightness == Brightness.dark ? '浅色' : '深色',
            onPressed: () => unawaited(
              state.setThemeMode(
                theme.brightness == Brightness.dark
                    ? ThemeMode.light
                    : ThemeMode.dark,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _accountButton(scheme),
        ],
      ),
    );
  }

  Widget _searchField(ThemeData theme, ColorScheme scheme) {
    return SizedBox(
      height: 50,
      child: TextField(
        controller: _search,
        onChanged: _onQueryChanged,
        textInputAction: TextInputAction.search,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: scheme.onSurface,
          height: 22 / 14,
        ),
        cursorColor: scheme.primary,
        decoration: InputDecoration(
          filled: true,
          fillColor: scheme.surface.withValues(alpha: 0.86),
          hintText: '搜索歌曲、歌手或歌单',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 19,
            color: scheme.primary,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: _search.text.isEmpty
              ? null
              : SizedBox.square(
                  dimension: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    tooltip: '清除',
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                    icon: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
          contentPadding: const EdgeInsets.symmetric(horizontal: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: scheme.outlineVariant),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(15),
            borderSide: BorderSide(color: scheme.primary, width: 1.2),
          ),
        ),
      ),
    );
  }

  Widget _barIconButton({
    required ColorScheme scheme,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox.square(
      dimension: 40,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
        ),
        icon: Icon(icon, size: 18),
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
            state.isGuest
                ? '游客模式'
                : '${state.user.name} · ${state.user.detail}',
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
    if (_comments) {
      final Track? track = state.current;
      final SongCommentsController? controller = _commentsController;
      if (track == null || controller == null) {
        return const LegacyNotice(message: '还没有播放中的曲目。');
      }
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: () => setState(() => _comments = false),
                  icon: const Icon(Icons.arrow_back_rounded, size: 20),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '评论 · ${track.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SongCommentsView(
              state: state,
              track: track,
              controller: controller,
            ),
          ),
        ],
      );
    }
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
              LegacyCover(
                url: widget.playlist.coverUrl,
                size: 34,
                radius: 8,
                iconSize: 14,
              ),
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
