import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../theme/apple_design.dart';
import '../widgets/apple_ui.dart';
import '../widgets/song_comments_view.dart';
import 'legacy_background.dart';
import 'legacy_login.dart';
import '../player/now_playing_page.dart';
import 'legacy_pages.dart';
import 'legacy_player_bar.dart';
import 'legacy_widgets.dart';

/// The app shell, rebuilt around Apple's adaptive navigation model.
///
/// Desktop gets a translucent source-list sidebar, a content toolbar and the
/// full transport, while phones get an inline navigation bar, the iOS tab bar
/// and a floating mini-player. Both compositions share one content tree, one
/// search state and one set of playback controls, so switching layouts never
/// loses context.
class LegacyShell extends StatefulWidget {
  const LegacyShell({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyShell> createState() => _LegacyShellState();
}

enum _LegacySection { home, library, likes, settings }

class _LegacyShellState extends State<LegacyShell>
    with SingleTickerProviderStateMixin {
  _LegacySection _section = _LegacySection.home;
  Playlist? _playlist;
  final TextEditingController _search = TextEditingController();
  String _query = '';
  Timer? _searchDebounce;
  bool _comments = false;
  bool _mobileSearchOpen = false;
  SongCommentsController? _commentsController;
  late final AnimationController _nowPlayingMotion;
  late final Animation<Offset> _nowPlayingSlide;
  bool _nowPlayingOpen = false;
  bool _nowPlayingSettled = true;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _nowPlayingMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 300),
    )..addStatusListener(_onNowPlayingStatus);
    _nowPlayingSlide = Tween<Offset>(
      begin: const Offset(0, .07),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _nowPlayingMotion,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
    );
  }

  void _onNowPlayingStatus(AnimationStatus status) {
    if (!mounted) return;
    if (status == AnimationStatus.completed && !_nowPlayingSettled) {
      setState(() => _nowPlayingSettled = true);
    } else if (status == AnimationStatus.dismissed && _nowPlayingOpen) {
      setState(() => _nowPlayingOpen = false);
    }
  }

  @override
  void dispose() {
    _nowPlayingMotion
      ..removeStatusListener(_onNowPlayingStatus)
      ..dispose();
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
    // Rebuild immediately for the clear affordance, even though the actual
    // query is debounced.
    if (mounted) setState(() {});
  }

  void _select(_LegacySection section) {
    _searchDebounce?.cancel();
    setState(() {
      _section = section;
      _playlist = null;
      _comments = false;
      _query = '';
      _mobileSearchOpen = false;
      if (_search.text.isNotEmpty) _search.clear();
    });
  }

  void _openPlaylist(Playlist playlist) {
    setState(() {
      _playlist = playlist;
      _comments = false;
      _query = '';
      _search.clear();
      _mobileSearchOpen = false;
    });
  }

  void _backToRoot() {
    _searchDebounce?.cancel();
    setState(() {
      _playlist = null;
      _comments = false;
      _query = '';
      _mobileSearchOpen = false;
      if (_search.text.isNotEmpty) _search.clear();
    });
  }

  void _toggleComments() {
    setState(() {
      _comments = !_comments;
      if (_comments) {
        _commentsController ??= SongCommentsController(state.gateway);
        _mobileSearchOpen = false;
      }
    });
  }

  void _toggleMobileSearch() {
    setState(() {
      _mobileSearchOpen = !_mobileSearchOpen;
      if (!_mobileSearchOpen && _search.text.isEmpty) _query = '';
    });
  }

  void _openNowPlaying() {
    if (_nowPlayingOpen) return;
    setState(() {
      _nowPlayingOpen = true;
      _nowPlayingSettled = false;
    });
    _nowPlayingMotion.forward(from: 0);
  }

  void _closeNowPlaying() {
    if (!_nowPlayingOpen) return;
    setState(() => _nowPlayingSettled = false);
    _nowPlayingMotion.reverse();
  }

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final Brightness brightness = Theme.of(context).brightness;
    final Color accent =
        state.legacyPalette == LegacyPaletteMode.nowPlaying &&
            state.legacySeed != null
        ? state.legacySeed!
        : AppleColors.musicRed;
    return Theme(
      data: buildAppleTheme(brightness: brightness, seedAccent: accent),
      child: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) {
          final AppleSemanticColors apple = AppleSemanticColors.of(context);
          final Size window = MediaQuery.sizeOf(context);
          final bool compact = useCompactLayout(state.uiMode, window.width);
          final bool compactBar = window.width < 1_000;
          final bool hasBackdrop =
              state.legacyBackground != LegacyBackgroundMode.off ||
              state.legacyPalette == LegacyPaletteMode.nowPlaying;
          final Widget shell = Scaffold(
            backgroundColor: apple.background,
            body: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                if (hasBackdrop)
                  LegacyAlbumBackdrop(
                    track: state.current,
                    mode: state.legacyBackground,
                    uiAlpha: state.legacyUiAlpha,
                    onSeed: state.setLegacySeed,
                  ),
                // Content sits on a semantic system background from which the
                // album tint is allowed to breathe through. Keeping this veil
                // opaque enough is what makes Apple's high-contrast labels
                // remain readable over arbitrary artwork.
                Positioned.fill(
                  child: ColoredBox(
                    color: hasBackdrop
                        ? apple.background.withValues(
                            alpha: (state.legacyUiAlpha * .9).clamp(.56, .92),
                          )
                        : apple.background,
                  ),
                ),
                SafeArea(
                  bottom: false,
                  child: compact
                      ? _compactLayout(apple, compactBar: compactBar)
                      : _desktopLayout(apple, compactBar: compactBar),
                ),
              ],
            ),
          );
          return Semantics(
            key: const ValueKey<String>('app-semantics-root'),
            container: true,
            label: 'Lazer',
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ExcludeSemantics(
                  excluding: _nowPlayingOpen,
                  child: ExcludeFocus(
                    excluding: _nowPlayingOpen,
                    child: TickerMode(
                      enabled: !_nowPlayingOpen,
                      child: RepaintBoundary(child: shell),
                    ),
                  ),
                ),
                if (_nowPlayingOpen)
                  Positioned.fill(
                    child: SlideTransition(
                      position: _nowPlayingSlide,
                      child: Semantics(
                        key: const ValueKey<String>('now-playing-semantics'),
                        container: true,
                        child: ExcludeSemantics(
                          excluding: !_nowPlayingSettled,
                          child: TickerMode(
                            enabled: _nowPlayingSettled,
                            child: RepaintBoundary(
                              child: NowPlayingPage(
                                state: state,
                                onClose: _closeNowPlaying,
                                entranceSettled: _nowPlayingSettled,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _desktopLayout(
    AppleSemanticColors apple, {
    required bool compactBar,
  }) {
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              _sidebar(apple),
              Container(width: .5, color: apple.separator),
              Expanded(
                child: Column(
                  children: <Widget>[
                    _desktopToolbar(apple),
                    Container(height: .5, color: apple.separator),
                    Expanded(child: RepaintBoundary(child: _content())),
                  ],
                ),
              ),
            ],
          ),
        ),
        RepaintBoundary(
          child: LegacyPlayerBar(
            state: state,
            compact: compactBar,
            comments: _comments,
            onComments: _toggleComments,
            onOpen: _openNowPlaying,
          ),
        ),
      ],
    );
  }

  Widget _compactLayout(
    AppleSemanticColors apple, {
    required bool compactBar,
  }) {
    return Column(
      children: <Widget>[
        _mobileToolbar(apple),
        if (_mobileSearchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: AppleSearchField(
              controller: _search,
              autofocus: true,
              onChanged: _onQueryChanged,
              onClear: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
          ),
        Expanded(child: RepaintBoundary(child: _content())),
        if (state.current != null)
          RepaintBoundary(
            child: LegacyPlayerBar(
              state: state,
              compact: true,
              comments: _comments,
              onComments: _toggleComments,
              onOpen: _openNowPlaying,
            ),
          ),
        AppleGlass(
          borderRadius: BorderRadius.zero,
          blurSigma: 28,
          color: apple.glass,
          border: Border(
            top: BorderSide(color: apple.separator, width: .5),
          ),
          child: NavigationBar(
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
        ),
      ],
    );
  }

  // -- sidebar and toolbars -------------------------------------------------

  Widget _sidebar(AppleSemanticColors apple) {
    return AppleGlass(
      borderRadius: BorderRadius.zero,
      blurSigma: 32,
      color: apple.glass.withValues(alpha: .92),
      child: SizedBox(
        width: 236,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
              child: Row(
                children: <Widget>[
                  const AppleIconTile(
                    icon: Icons.graphic_eq_rounded,
                    size: 30,
                    iconSize: 18,
                    radius: 7,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Lazer',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: apple.label,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: <Widget>[
                  _sidebarLabel(apple, '浏览'),
                  LegacyRailItem(
                    icon: Icons.home_rounded,
                    label: '主页',
                    selected:
                        _section == _LegacySection.home &&
                        _playlist == null &&
                        !_comments,
                    onTap: () => _select(_LegacySection.home),
                  ),
                  const SizedBox(height: 2),
                  LegacyRailItem(
                    icon: Icons.library_music_rounded,
                    label: '音乐库',
                    selected:
                        _section == _LegacySection.library &&
                        _playlist == null &&
                        !_comments,
                    onTap: () => _select(_LegacySection.library),
                  ),
                  const SizedBox(height: 2),
                  LegacyRailItem(
                    icon: Icons.favorite_rounded,
                    label: '我喜欢',
                    selected:
                        _section == _LegacySection.likes &&
                        _playlist == null &&
                        !_comments,
                    onTap: () => _select(_LegacySection.likes),
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: <Widget>[
                      Expanded(child: _sidebarLabel(apple, '资料库')),
                      if (state.signedIn)
                        _SidebarIconButton(
                          tooltip: '同步歌单',
                          icon: Icons.sync_rounded,
                          onPressed: () =>
                              unawaited(state.refreshCollections(force: true)),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  _railPlaylists(apple),
                ],
              ),
            ),
            Container(height: .5, color: apple.separator),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
              child: Column(
                children: <Widget>[
                  LegacyRailItem(
                    icon: Icons.settings_rounded,
                    label: '设置',
                    selected: _section == _LegacySection.settings,
                    onTap: () => _select(_LegacySection.settings),
                  ),
                  const SizedBox(height: 4),
                  _accountRow(apple),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarLabel(AppleSemanticColors apple, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 12, 9, 5),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: apple.secondaryLabel,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _desktopToolbar(AppleSemanticColors apple) {
    final bool canGoBack =
        _playlist != null || _comments || _query.isNotEmpty;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: <Widget>[
            if (canGoBack) ...<Widget>[
              _ToolbarButton(
                tooltip: '返回',
                icon: Icons.chevron_left_rounded,
                onPressed: _backToRoot,
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: AppleSearchField(
                    controller: _search,
                    onChanged: _onQueryChanged,
                    onClear: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
                ),
              ),
            ),
            const Spacer(),
            _ToolbarButton(
              tooltip: Theme.of(context).brightness == Brightness.dark
                  ? '浅色外观'
                  : '深色外观',
              icon: Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              onPressed: () => unawaited(
                state.setThemeMode(
                  Theme.of(context).brightness == Brightness.dark
                      ? ThemeMode.light
                      : ThemeMode.dark,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _accountButton(apple),
          ],
        ),
      ),
    );
  }

  Widget _mobileToolbar(AppleSemanticColors apple) {
    final bool canGoBack =
        _playlist != null || _comments || _query.isNotEmpty;
    return SizedBox(
      height: 50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            if (canGoBack)
              _ToolbarButton(
                tooltip: '返回',
                icon: Icons.chevron_left_rounded,
                onPressed: _backToRoot,
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: AppleIconTile(
                  icon: Icons.graphic_eq_rounded,
                  size: 28,
                  iconSize: 17,
                  radius: 7,
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                canGoBack ? _pageTitle : 'Lazer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: apple.label,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            _ToolbarButton(
              tooltip: _mobileSearchOpen ? '关闭搜索' : '搜索',
              icon: _mobileSearchOpen ? Icons.close_rounded : Icons.search_rounded,
              selected: _mobileSearchOpen,
              onPressed: _toggleMobileSearch,
            ),
            _ToolbarButton(
              tooltip: Theme.of(context).brightness == Brightness.dark
                  ? '浅色外观'
                  : '深色外观',
              icon: Theme.of(context).brightness == Brightness.dark
                  ? Icons.light_mode_rounded
                  : Icons.dark_mode_rounded,
              onPressed: () => unawaited(
                state.setThemeMode(
                  Theme.of(context).brightness == Brightness.dark
                      ? ThemeMode.light
                      : ThemeMode.dark,
                ),
              ),
            ),
            const SizedBox(width: 2),
            _accountButton(apple, radius: 15),
          ],
        ),
      ),
    );
  }

  String get _pageTitle {
    if (_comments) return '评论';
    if (_query.isNotEmpty) return '搜索';
    if (_playlist != null) return _playlist!.name;
    return switch (_section) {
      _LegacySection.home => '现在就听',
      _LegacySection.library => '资料库',
      _LegacySection.likes => '我喜欢的音乐',
      _LegacySection.settings => '设置',
    };
  }

  Widget _railPlaylists(AppleSemanticColors apple) {
    final List<Playlist> playlists = <Playlist>[
      if (state.collections.liked != null) state.collections.liked!,
      ...state.collections.created,
      ...state.collections.subscribed,
    ];
    if (playlists.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(9, 5, 9, 8),
        child: Text(
          state.isGuest ? '登录后同步你的歌单' : '暂无歌单',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: apple.tertiaryLabel,
          ),
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final Playlist playlist in playlists)
          _RailPlaylist(
            playlist: playlist,
            selected: _playlist?.id == playlist.id,
            onTap: () => _openPlaylist(playlist),
          ),
      ],
    );
  }

  Widget _accountRow(AppleSemanticColors apple) {
    final String name = state.isGuest ? '游客' : state.user.name;
    final String detail = state.isGuest ? '登录以同步资料库' : state.user.detail;
    return AppleListTile(
      title: name,
      subtitle: detail,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      minHeight: 40,
      leading: _Avatar(apple: apple, radius: 14, label: _accountInitial),
      onTap: () => unawaited(showLegacyLoginDialog(context, state)),
    );
  }

  String get _accountInitial {
    if (state.isGuest) return '访';
    final String name = state.user.name.trim();
    if (name.isEmpty) return '你';
    return name.characters.first;
  }

  Widget _accountButton(
    AppleSemanticColors apple, {
    double radius = 15,
  }) {
    return PopupMenuButton<String>(
      tooltip: state.isGuest ? '登录' : state.user.name,
      offset: const Offset(0, 42),
      color: apple.tertiaryBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: apple.secondaryLabel,
            ),
          ),
        ),
        if (state.isGuest)
          const PopupMenuItem<String>(value: 'login', child: Text('登录'))
        else
          const PopupMenuItem<String>(value: 'logout', child: Text('退出登录')),
        const PopupMenuItem<String>(value: 'settings', child: Text('设置')),
      ],
      child: _Avatar(
        apple: apple,
        radius: radius,
        label: _accountInitial,
      ),
    );
  }

  // -- content --------------------------------------------------------------

  Widget _content() {
    if (_comments) {
      final Track? track = state.current;
      final SongCommentsController? controller = _commentsController;
      if (track == null || controller == null) {
        return const LegacyNotice(message: '还没有播放中的歌曲。');
      }
      return Column(
        children: <Widget>[
          ApplePageTitle(
            title: '评论',
            subtitle: track.title,
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 6),
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

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: widget.selected
                  ? apple.fill
                  : _hovering
                  ? apple.tertiaryFill
                  : Colors.transparent,
              shape: BoxShape.circle,
            ),
            child: Icon(
              widget.icon,
              size: 20,
              color: widget.selected ? apple.accent : apple.secondaryLabel,
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarIconButton extends StatelessWidget {
  const _SidebarIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 15,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: apple.accent,
        backgroundColor: apple.fill,
      ),
      icon: Icon(icon),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.apple, required this.radius, required this.label});

  final AppleSemanticColors apple;
  final double radius;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.lerp(apple.accent, Colors.white, .18)!,
            apple.accent,
          ],
        ),
        shape: BoxShape.circle,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
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
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 34,
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 7),
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
              LegacyCover(
                url: widget.playlist.coverUrl,
                size: 24,
                radius: 5,
                iconSize: 12,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: widget.selected ? apple.label : apple.secondaryLabel,
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
