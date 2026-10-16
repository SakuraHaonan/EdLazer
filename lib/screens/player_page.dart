import 'package:lazer_nextgen/theme/app_palette.dart';
import '../l10n/app_localizations.dart';
import '../l10n/app_language.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/scroll_inertia_setting.dart';
import '../widgets/lyric_typography_setting.dart';
import '../widgets/catalog_links.dart';
import '../widgets/square_switch_list_tile.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/haptic_seek_slider.dart';
import '../widgets/volume_control.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;

import '../data/catalog.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';
import '../widgets/plate_art.dart';
import '../widgets/animated_notice.dart';
import 'login_page.dart';
import 'now_playing_page.dart';
import 'playlist_detail_page.dart';

enum NavSection { home, search, likes, settings, user }

void _openPlaylist(BuildContext context, AppState state, Playlist playlist) {
  unawaited(state.feedback());
  final shell = context.findAncestorStateOfType<_PlayerPageState>();
  if (MediaQuery.sizeOf(context).width >= _compactBreakpoint && shell != null) {
    shell.openPlaylist(playlist);
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PlaylistDetailPage(playlist: playlist, state: state),
    ),
  );
}

class PlayerControlsBar extends StatelessWidget {
  const PlayerControlsBar({
    super.key,
    required this.state,
    required this.onExpand,
    this.includeBottomSafeArea = false,
  });
  final AppState state;
  final VoidCallback onExpand;
  final bool includeBottomSafeArea;

  @override
  Widget build(BuildContext context) => _PlayerBar(
    state: state,
    onExpand: onExpand,
    compact: MediaQuery.sizeOf(context).width < _compactBreakpoint,
    includeBottomSafeArea: includeBottomSafeArea,
  );
}

Future<void> _playCollection(BuildContext context, Future<void> action) async {
  try {
    await action;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: TrText('曲目加载失败，请检查网络后重试。')));
    }
  }
}

extension on NavSection {
  String get label => switch (this) {
    NavSection.home => '主页',
    NavSection.search => '搜索',
    NavSection.likes => '我喜欢',
    NavSection.settings => '设置',
    NavSection.user => '我',
  };
  IconData get icon => switch (this) {
    NavSection.home => Icons.home_outlined,
    NavSection.search => Icons.search_outlined,
    NavSection.likes => Icons.favorite_border_rounded,
    NavSection.settings => Icons.settings_outlined,
    NavSection.user => Icons.person_outline,
  };
}

/// Below this width the left rail collapses into a bottom tab bar and the
/// player bar drops its secondary controls — the mobile shell.
const double _compactBreakpoint = 720;

/// Bottom padding handed to the scrolling page so the floating compact
/// transport never covers the last row of content.

/// The signed-in player shell: a parchment workspace framed by a left nav
/// rail (bottom tab bar when compact). Desktop grounds it with the dark
/// player bar (the single inversion surface); the compact shell floats its
/// transport over the page instead.
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.state});

  final AppState state;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  NavSection _section = NavSection.home;
  Playlist? _playlist;

  void openPlaylist(Playlist playlist) => setState(() {
    _playlist = playlist;
    if (playlist.id == widget.state.collections.liked?.id) {
      _section = NavSection.likes;
    } else if (_section == NavSection.likes) {
      _section = NavSection.home;
    }
  });

  void _backToLibrary() => setState(() {
    _playlist = null;
    if (_section == NavSection.likes) _section = NavSection.home;
  });

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const TrText('设置')),
          body: AnimatedBuilder(
            animation: widget.state,
            builder: (context, _) => SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _SettingsView(state: widget.state, showHeading: false),
            ),
          ),
        ),
      ),
    );
  }

  void _openNowPlaying() {
    Navigator.of(context).push(NowPlayingRoute(state: widget.state));
  }

  void _selectSection(NavSection s) {
    if (s == _section && _playlist == null) return;
    unawaited(widget.state.feedback());
    setState(() {
      _section = s;
      _playlist = null;
    });
    if (s == NavSection.likes && widget.state.isGuest) {
      unawaited(showLoginDialog(context, widget.state));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.colors.ivoryMedium,
      // One shell, two layouts: the width decides whether the rail lives on
      // the left or along the bottom.
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool compact = constraints.maxWidth < _compactBreakpoint;
          final selectedPlaylist =
              _playlist ??
              (_section == NavSection.likes
                  ? widget.state.collections.liked
                  : null);
          final Widget content = SafeArea(
            top: compact,
            bottom: false,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!compact) ...[
                  _Sidebar(
                    state: widget.state,
                    section: _section,
                    onSection: _selectSection,
                    onPlaylist: openPlaylist,
                    selectedPlaylistId: selectedPlaylist?.id,
                    onSettings: () => _selectSection(NavSection.settings),
                  ),
                  const Hairline(vertical: true),
                ],
                Expanded(
                  child: Column(
                    children: [
                      if (compact)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Lazer',
                                  style: context.type.bodySm,
                                ),
                              ),
                              AccessibleIconButton(
                                tooltip: '设置',
                                onPressed: _openSettings,
                                icon: const Icon(
                                  Icons.settings_outlined,
                                  size: 22,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Expanded(
                        child: _ViewEntry(
                          id: selectedPlaylist == null
                              ? _section.name
                              : 'playlist_${selectedPlaylist.id}',
                          child: selectedPlaylist != null
                              ? PlaylistDetailView(
                                  playlist: selectedPlaylist,
                                  state: widget.state,
                                  onBack: _backToLibrary,
                                )
                              : _LibraryView(
                                  state: widget.state,
                                  section: _section,
                                  bottomInset: 0,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
          if (!compact) {
            return Column(
              children: [
                Expanded(child: content),
                _PlayerBar(state: widget.state, onExpand: _openNowPlaying),
              ],
            );
          }
          return Column(
            children: [
              Expanded(child: content),
              _PlayerBar(
                state: widget.state,
                onExpand: _openNowPlaying,
                compact: true,
              ),
              _BottomNav(section: _section, onSection: _selectSection),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.state,
    required this.section,
    required this.onSection,
    required this.onPlaylist,
    required this.onSettings,
    this.selectedPlaylistId,
  });
  final AppState state;
  final NavSection section;
  final ValueChanged<NavSection> onSection;
  final ValueChanged<Playlist> onPlaylist;
  final VoidCallback onSettings;
  final String? selectedPlaylistId;
  static final sections = [
    NavSection.home,
    NavSection.search,
    NavSection.likes,
    NavSection.user,
  ];

  @override
  Widget build(BuildContext context) {
    final selected = sections.indexOf(section);
    final navigationActive =
        selectedPlaylistId == null ||
        (section == NavSection.likes &&
            selectedPlaylistId == state.collections.liked?.id);
    final playlists = [
      ...state.collections.created,
      ...state.collections.subscribed,
    ];
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
          child: InkWell(
            borderRadius: BorderRadius.zero,
            onTap: () => state.isGuest
                ? showLoginDialog(context, state)
                : onSection(NavSection.user),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox.square(
                    dimension: 36,
                    child: state.user.avatarUrl == null
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              color: context.colors.oatWarm,
                              shape: BoxShape.rectangle,
                            ),
                            child: const Icon(
                              Icons.person_outline_rounded,
                              size: 22,
                            ),
                          )
                        : PlateArt(
                            seed: state.user.userId,
                            coverUrl: state.user.avatarUrl,
                            radius: BorderRadius.zero,
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          state.isGuest
                              ? context.tr(state.user.name)
                              : state.user.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.bodySm.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        TrText(
                          state.isGuest ? '点此登录' : '我的音乐',
                          style: context.type.captionMuted,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        SizedBox(
          height: sections.length * 44.0,
          child: Stack(
            children: [
              Column(
                children: [
                  for (final item in sections)
                    _NavItem(
                      label: item.label,
                      icon: item.icon,
                      active: section == item && navigationActive,
                      onTap: () => onSection(item),
                    ),
                ],
              ),
              AnimatedPositioned(
                key: const ValueKey('sidebar-selection-marker'),
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeInOutCubic,
                left: 24,
                top: (selected < 0 ? 0 : selected) * 44.0 + 13,
                width: 2,
                height: 18,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: selected < 0 || !navigationActive ? 0 : 1,
                    duration: const Duration(milliseconds: 160),
                    child: ColoredBox(color: context.colors.slateDark),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Hairline(),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24, right: 12),
          child: Row(
            children: [
              Expanded(
                child: TrText('我的歌单', style: context.type.captionStrong),
              ),
              if (state.signedIn)
                AccessibleIconButton(
                  tooltip: '刷新歌单',
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  onPressed: () =>
                      unawaited(state.refreshCollections(force: true)),
                ),
            ],
          ),
        ),
        Expanded(
          child: state.isGuest
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: TrText('登录后同步你的歌单', style: context.type.captionMuted),
                )
              : playlists.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TrText(
                        state.collectionsLoading
                            ? '正在同步歌单…'
                            : state.collectionsError ?? '暂无歌单',
                        style: context.type.captionMuted,
                      ),
                      if (state.collectionsError != null)
                        TextButton(
                          onPressed: () =>
                              unawaited(state.refreshCollections(force: true)),
                          child: const TrText('重试'),
                        ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: playlists.length,
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Material(
                        color: selectedPlaylistId == playlist.id
                            ? context.colors.oatWarm
                            : Colors.transparent,
                        borderRadius: BorderRadius.zero,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          borderRadius: BorderRadius.zero,
                          hoverColor: context.colors.oatWarm.withValues(
                            alpha: 0.5,
                          ),
                          onTap: () => onPlaylist(playlist),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              children: [
                                SizedBox.square(
                                  dimension: 32,
                                  child: PlateArt(
                                    seed: playlist.coverSeed,
                                    coverUrl: playlist.coverUrl,
                                    radius: BorderRadius.zero,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    playlist.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: context.type.caption.copyWith(
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 24),
          child: Hairline(),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Stack(
            children: [
              _NavItem(
                label: '设置',
                icon: Icons.settings_outlined,
                active: section == NavSection.settings,
                onTap: onSettings,
              ),
              Positioned(
                left: 24,
                top: 13,
                width: 2,
                height: 18,
                child: ExcludeSemantics(
                  child: IgnorePointer(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween(
                            begin: const Offset(0, 1),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: section == NavSection.settings
                          ? ColoredBox(
                              key: const ValueKey('settings-selection-marker'),
                              color: context.colors.slateDark,
                              child: const SizedBox.expand(),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('settings-marker-hidden'),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return SizedBox(
      width: 232,
      child: LayoutBuilder(
        builder: (context, box) => box.maxHeight >= 420
            ? content
            : SingleChildScrollView(
                child: SizedBox(height: 420, child: content),
              ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: active
            ? context.colors.oatWarm.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.zero,
          hoverColor: context.colors.ivoryLight,
          onTap: feedbackAction(context, onTap),
          child: Padding(
            padding: const EdgeInsets.only(left: 28, right: 16),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: active
                      ? context.colors.slateDark
                      : context.colors.cloudDark,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TrText(
                    label,
                    style: context.type.bodySm.copyWith(
                      fontSize: 15,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active
                          ? context.colors.slateDark
                          : context.colors.cloudDark,
                    ),
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

/// Incoming content animates without keeping a second accessibility tree alive.
class _ViewEntry extends StatelessWidget {
  const _ViewEntry({required this.id, required this.child});
  final String id;
  final Widget child;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    key: ValueKey(id),
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 360),
    curve: Curves.easeOutQuart,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(0, (1 - value) * 32),
        child: Transform.scale(scale: 0.96 + value * 0.04, child: child),
      ),
    ),
    child: child,
  );
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.section, required this.onSection});

  final NavSection section;
  final ValueChanged<NavSection> onSection;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.ivoryLight,
        border: Border(top: context.borders.hairline),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final NavSection s in [
                NavSection.home,
                NavSection.search,
                NavSection.user,
              ])
                Expanded(
                  child: _BottomNavItem(
                    section: s,
                    active: s == section,
                    onTap: () => onSection(s),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BottomNavItem extends StatelessWidget {
  const _BottomNavItem({
    required this.section,
    required this.active,
    required this.onTap,
  });

  final NavSection section;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color fg = active
        ? context.colors.slateDark
        : context.colors.cloudDark;
    return Semantics(
      button: true,
      selected: active,
      label: context.tr(section.label),
      child: Material(
        color: active
            ? context.colors.oatWarm.withValues(alpha: 0.55)
            : context.colors.ivoryLight,
        child: InkWell(
          onTap: feedbackAction(context, onTap),
          child: Ink(
            child: Stack(
              children: [
                // Same slate tick as the rail, rotated to the tab's top edge.
                if (active)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        width: 28,
                        height: 2,
                        color: context.colors.slateDark,
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(section.icon, size: 20, color: fg),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TrText(
                          section.label,
                          style: context.type.caption.copyWith(
                            fontSize: 11,
                            color: active
                                ? context.colors.slateDark
                                : context.colors.cloudMedium,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
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

// ---------------------------------------------------------------------------
// Library content
// ---------------------------------------------------------------------------

class _LibraryView extends StatefulWidget {
  const _LibraryView({
    required this.state,
    required this.section,
    this.bottomInset = 0,
  });

  final AppState state;
  final NavSection section;

  /// Extra scroll padding under the last row (the floating compact bar).
  final double bottomInset;

  @override
  State<_LibraryView> createState() => _LibraryViewState();
}

class _LibraryViewState extends State<_LibraryView> {
  late final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double w = constraints.maxWidth;
        final EdgeInsets page = EdgeInsets.fromLTRB(
          w > 900
              ? 56
              : w < 560
              ? AppSpacing.lg
              : 32,
          AppSpacing.xl,
          w > 900
              ? 56
              : w < 560
              ? AppSpacing.lg
              : 32,
          AppSpacing.xl + widget.bottomInset,
        );
        return SingleChildScrollView(
          controller: _scrollController,
          primary: false,
          padding: page,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1020),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedNotice(
                  message: widget.state.playbackError,
                  onDismiss: widget.state.clearPlaybackError,
                ),
                switch (widget.section) {
                  NavSection.home => _HomeView(state: widget.state),
                  NavSection.search => _SearchView(state: widget.state),
                  NavSection.likes => _EmptyHint(
                    icon: Icons.favorite_border_rounded,
                    title: '喜欢的音乐',
                    body: widget.state.isGuest ? '登录后查看喜欢的音乐。' : '正在读取喜欢的音乐…',
                  ),
                  NavSection.settings => _SettingsView(state: widget.state),
                  NavSection.user => _MeView(state: widget.state),
                },
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Hero heading block: sans display statement on the left, serif editorial
/// paragraph on the right — asymmetric, generous whitespace.
class _HeroHeading extends StatelessWidget {
  const _HeroHeading({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final bool wide = c.maxWidth > 720;
        final Widget left = TrText(
          title,
          style: context.type.heading.copyWith(
            fontSize: wide
                ? 56
                : c.maxWidth < 560
                ? 32
                : 40,
          ),
        );
        final Widget right = TrText(
          body,
          style: context.type.body.copyWith(
            color: context.colors.cloudDark,
            height: 1.5,
          ),
        );
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              left,
              const SizedBox(height: AppSpacing.md),
              right,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 3, child: left),
            const SizedBox(width: AppSpacing.xl),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: right,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeView extends StatelessWidget {
  const _HomeView({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final HomeFeed? feed = state.home;
    if (feed == null || feed.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _HeroHeading(title: '发现音乐', body: '浏览真实歌单，挑一首开始播放。'),
          const SizedBox(height: AppSpacing.lg),
          _EmptyHint(
            icon: Icons.cloud_off_outlined,
            title: state.homeError == null ? '正在加载曲库' : '曲库暂时不可用',
            body: state.homeError ?? '请稍候。',
          ),
          const SizedBox(height: AppSpacing.md),
          IvoryButton(
            label: '重新加载',
            onPressed: () => unawaited(state.refreshHome(force: true)),
          ),
        ],
      );
    }
    final recommended = feed.recommended;
    final List<Track> quick = feed.quick;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HeroHeading(title: '今天想听\n哪一首？', body: ''),
        const SizedBox(height: AppSpacing.section * 0.6),
        if (recommended.isNotEmpty) ...[
          const SectionHeading('推荐歌单'),
          const SizedBox(height: AppSpacing.md),
          _RecommendedPlaylists(playlists: recommended, state: state),
          const SizedBox(height: AppSpacing.section * 0.6),
        ],
        if (quick.isNotEmpty) ...[
          const SectionHeading('快速开始'),
          const SizedBox(height: AppSpacing.md),
          _stackedRows([
            for (int i = 0; i < quick.length; i++)
              TrackRow(
                state: state,
                track: quick[i],
                index: i + 1,
                isCurrent: state.current?.id == quick[i].id,
                onPlay: () => state.playQueue(quick, startIndex: i),
              ),
          ], indent: 64),
          const SizedBox(height: AppSpacing.section * 0.6),
        ],
        if (feed.playlists.isNotEmpty) ...[
          const SectionHeading('歌单'),
          const SizedBox(height: AppSpacing.md),
          _PlaylistGrid(playlists: feed.playlists, state: state),
          const SizedBox(height: AppSpacing.section * 0.6),
        ],
        if (feed.albums.isNotEmpty) ...[
          const SectionHeading('专辑'),
          const SizedBox(height: AppSpacing.md),
          _AlbumGrid(albums: feed.albums, state: state),
        ],
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

class _RecommendedPlaylists extends StatelessWidget {
  const _RecommendedPlaylists({required this.playlists, required this.state});
  final List<Playlist> playlists;
  final AppState state;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final columns = (box.maxWidth / 180).floor().clamp(2, 4);
      final width = (box.maxWidth - 16 * (columns - 1)) / columns;
      return Wrap(
        spacing: 16,
        runSpacing: 24,
        children: [
          for (final playlist in playlists.take(columns))
            SizedBox(
              width: width,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _openPlaylist(context, state, playlist),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: PlateArt(
                          seed: playlist.coverSeed,
                          coverUrl: playlist.coverUrl,
                          radius: BorderRadius.zero,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        playlist.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodySm.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (playlist.description.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          playlist.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.captionMuted,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Curated collections as a shelf: two-up on wide canvases, stacked and
/// taller-boxed when the content column narrows.
class _PlaylistGrid extends StatelessWidget {
  const _PlaylistGrid({required this.playlists, required this.state});

  final List<Playlist> playlists;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final int cols = c.maxWidth > 760 ? 2 : 1;
        return GridView.builder(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisExtent:
                180 +
                (MediaQuery.textScalerOf(context).scale(16) - 16).clamp(0, 24) *
                    4,
            mainAxisSpacing: AppSpacing.md,
            crossAxisSpacing: AppSpacing.md,
          ),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: playlists.length,
          itemBuilder: (context, index) =>
              _PlaylistCard(playlist: playlists[index], state: state),
        );
      },
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist, required this.state});
  final Playlist playlist;
  final AppState state;

  @override
  Widget build(BuildContext context) => Material(
    color: context.colors.ivoryLight,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.zero,
      side: BorderSide(color: context.colors.stone),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _openPlaylist(context, state, playlist),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 100,
            child: PlateArt(
              seed: playlist.coverSeed,
              coverUrl: playlist.coverUrl,
              radius: BorderRadius.zero,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.bodySm.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    playlist.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.captionMuted,
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: context.colors.slateDark,
                        ),
                        onPressed: () => unawaited(
                          _playCollection(
                            context,
                            state.playPlaylist(playlist.id),
                          ),
                        ),
                        child: const TrText('播放'),
                      ),
                      TrText(
                        '${playlist.trackCount} 首',
                        style: context.type.captionMuted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _AlbumGrid extends StatelessWidget {
  const _AlbumGrid({required this.albums, required this.state});

  final List<Album> albums;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final int cols = c.maxWidth > 820
            ? 4
            : c.maxWidth > 560
            ? 3
            : 2;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.md,
          crossAxisSpacing: AppSpacing.md,
          childAspectRatio: 0.74,
          children: [
            for (final Album a in albums) _AlbumCard(album: a, state: state),
          ],
        );
      },
    );
  }
}

class _AlbumCard extends StatelessWidget {
  const _AlbumCard({required this.album, required this.state});

  final Album album;
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: AspectRatio(
            aspectRatio: 1,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: feedbackAction(
                  context,
                  () => unawaited(openAlbumDetails(context, state, album)),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PlateArt(
                      seed: album.coverSeed,
                      accent: album.accent,
                      coverUrl: album.coverUrl,
                    ),
                    Positioned(
                      right: 10,
                      bottom: 10,
                      child: AccessibleIconButton(
                        tooltip: '播放专辑',
                        onPressed: () => unawaited(
                          _playCollection(context, state.playAlbum(album.id)),
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: context.colors.slateDark,
                          foregroundColor: context.colors.onInk,
                        ),
                        icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        CatalogTextLink(
          text: album.title,
          onTap: () => unawaited(openAlbumDetails(context, state, album)),
          style: context.type.body.copyWith(fontSize: 16, height: 1.3),
        ),
        ArtistNameLink(
          state: state,
          artists: album.artists,
          fallback: album.artist,
          style: context.type.captionMuted,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Shared list chrome — rows stacked in a card, split by hairlines
// ---------------------------------------------------------------------------

/// Rows stacked inside a card, separated by hairlines. [indent] pushes the
/// rules clear of a leading cover column (0 for plain settings rows);
/// [radius] lets a page opt out of the card round (the settings sheet is
/// squared off, print-table style).
Widget _stackedRows(
  List<Widget> rows, {
  double indent = 0,
  double radius = AppRadius.card,
}) {
  return PaperCard(
    padding: EdgeInsets.zero,
    radius: radius,
    child: Column(
      children: [
        for (int i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1)
            Padding(
              padding: EdgeInsets.only(left: indent),
              child: const Hairline(),
            ),
        ],
      ],
    ),
  );
}

/// Spare empty / no-result state: line icon, serif title, muted caption.
class _EmptyHint extends StatelessWidget {
  const _EmptyHint({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return PaperCard(
      child: Column(
        children: [
          Icon(icon, size: 28, color: context.colors.cloudDark),
          const SizedBox(height: AppSpacing.md),
          TrText(
            title,
            textAlign: TextAlign.center,
            style: context.type.subheading.copyWith(fontSize: 18),
          ),
          const SizedBox(height: AppSpacing.xs),
          TrText(
            body,
            textAlign: TextAlign.center,
            style: context.type.captionMuted.copyWith(height: 1.5),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

/// Hairline search input — the login field's chrome, with a clear affordance
/// once the query has content.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (bool f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        constraints: const BoxConstraints(minHeight: 52),
        decoration: BoxDecoration(
          color: context.colors.ivoryLight,
          borderRadius: BorderRadius.zero,
          border: Border.all(
            color: _focused ? context.colors.slateDark : context.colors.stone,
            width: 1,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
        child: Row(
          children: [
            Icon(
              Icons.search_outlined,
              size: 17,
              color: context.colors.cloudDark,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: widget.onChanged,
                style: context.type.bodySm.copyWith(fontSize: 16),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: false,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  border: InputBorder.none,
                  hintText: context.tr('搜索曲目、专辑或歌单'),
                  hintStyle: context.type.bodySm.copyWith(
                    fontSize: 16,
                    color: context.colors.cloudMedium,
                  ),
                ),
              ),
            ),
            if (widget.controller.text.isNotEmpty)
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    widget.controller.clear();
                    widget.onChanged('');
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: context.colors.cloudDark,
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

/// One search box over the whole catalogue; an empty query doubles as the
/// full track list, so the section is never a dead end. A non-empty query
/// Searches songs, albums, and playlists through the gateway.
class _SearchView extends StatefulWidget {
  const _SearchView({required this.state});

  final AppState state;

  @override
  State<_SearchView> createState() => _SearchViewState();
}

class _SearchViewState extends State<_SearchView> {
  final TextEditingController _query = TextEditingController();
  String _q = '';
  SearchResults _results = SearchResults.empty;
  Timer? _debounce;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final String q = value.trim();
    _debounce?.cancel();
    if (q.isEmpty) {
      setState(() {
        _q = value;
        _results = SearchResults.empty;
        _busy = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _q = value;
      _results = SearchResults.empty;
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 350), () => _remote(q));
  }

  Future<void> _remote(String q) async {
    setState(() => _busy = true);
    try {
      final SearchResults results = await widget.state.search(q);
      if (!mounted || _q.trim() != q) return;
      setState(() {
        _results = results;
        _busy = false;
        _error = null;
      });
    } catch (_) {
      if (!mounted || _q.trim() != q) return;
      setState(() {
        _busy = false;
        _error = '搜索失败，请检查网络后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final String q = _q.trim();
    final bool filtering = q.isNotEmpty;
    final List<Track> tracks = _results.tracks;
    final List<Album> albums = filtering ? _results.albums : <Album>[];
    final List<Playlist> playlists = filtering
        ? _results.playlists
        : <Playlist>[];
    final int hits = tracks.length + albums.length + playlists.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HeroHeading(title: '搜索', body: '搜索曲名、音乐人、专辑或歌单。'),
        const SizedBox(height: AppSpacing.section * 0.5),
        _SearchField(controller: _query, onChanged: _onChanged),
        if (filtering) ...[
          const SizedBox(height: AppSpacing.sm),
          TrText(
            _busy ? '正在检索…' : _error ?? '$hits 条匹配',
            style: context.type.captionMuted,
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        if (_error != null)
          IvoryButton(label: '重试搜索', onPressed: () => unawaited(_remote(q)))
        else if (!filtering)
          const _EmptyHint(
            icon: Icons.search_rounded,
            title: '开始搜索',
            body: '输入你想听的曲名或音乐人。',
          )
        else if (!_busy && hits == 0)
          const _EmptyHint(
            icon: Icons.search_off_rounded,
            title: '没有找到结果',
            body: '换一个关键词再试。',
          )
        else ...[
          if (tracks.isNotEmpty) ...[
            SectionHeading('曲目 · ${tracks.length}'),
            const SizedBox(height: AppSpacing.md),
            _stackedRows([
              for (int i = 0; i < tracks.length; i++)
                TrackRow(
                  state: widget.state,
                  track: tracks[i],
                  index: i + 1,
                  isCurrent: widget.state.current?.id == tracks[i].id,
                  onPlay: () => widget.state.playQueue(tracks, startIndex: i),
                ),
            ], indent: 64),
          ],
          if (albums.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.section * 0.5),
            SectionHeading('专辑 · ${albums.length}'),
            const SizedBox(height: AppSpacing.md),
            _stackedRows([
              for (final Album a in albums)
                _MediaRow(
                  title: a.title,
                  subtitle: a.artist.isEmpty
                      ? a.year
                      : '${a.artist} · ${a.year}',
                  trailing: a.trackCount != null ? '${a.trackCount} 首' : '',
                  coverSeed: a.coverSeed,
                  accent: a.accent,
                  coverUrl: a.coverUrl,
                  onPlay: () =>
                      unawaited(openAlbumDetails(context, widget.state, a)),
                ),
            ], indent: 64),
          ],
          if (playlists.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.section * 0.5),
            SectionHeading('歌单 · ${playlists.length}'),
            const SizedBox(height: AppSpacing.md),
            _stackedRows([
              for (final Playlist p in playlists)
                _MediaRow(
                  title: p.name,
                  subtitle: p.description,
                  trailing: p.trackCount > 0 ? '${p.trackCount} 首' : '',
                  coverSeed: p.coverSeed,
                  coverUrl: p.coverUrl,
                  onPlay: () => _openPlaylist(context, widget.state, p),
                ),
            ], indent: 64),
          ],
        ],
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// Compact catalogue row for albums and playlists: plate, title, muted
/// subtitle, count — tap anywhere to play.
class _MediaRow extends StatelessWidget {
  const _MediaRow({
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.coverSeed,
    required this.onPlay,
    this.accent = 0,
    this.coverUrl,
  });

  final String title;
  final String subtitle;
  final String trailing;
  final int coverSeed;
  final int accent;
  final String? coverUrl;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onPlay == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPlay,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 10,
          ),
          child: Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: PlateArt(
                  seed: coverSeed,
                  accent: accent,
                  coverUrl: coverUrl,
                  radius: BorderRadius.zero,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.body.copyWith(
                        fontSize: 16,
                        height: 1.3,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              TrText(trailing, style: context.type.monoSm),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

class _SettingsView extends StatelessWidget {
  const _SettingsView({required this.state, this.showHeading = true});

  final AppState state;
  final bool showHeading;

  @override
  Widget build(BuildContext context) {
    final SessionUser user = state.user;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeading) ...[
          const _HeroHeading(title: '设置', body: '管理登录账户和曲库同步。'),
          const SizedBox(height: AppSpacing.section * 0.5),
        ],

        const SectionHeading('账户'),
        const SizedBox(height: AppSpacing.md),
        _stackedRows([
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: context.colors.manilla,
                    shape: BoxShape.rectangle,
                  ),
                  child: Text(
                    (user.isGuest ? context.tr(user.name) : user.name)
                        .characters
                        .first,
                    style: context.type.body.copyWith(fontSize: 18, height: 1),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.isGuest ? context.tr(user.name) : user.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.bodySm.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${context.tr(user.methodLabel)} · ${context.tr(user.detail)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.type.captionMuted,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _ActionRow(
            label: state.isGuest ? '登录' : '退出登录',
            icon: state.isGuest ? Icons.login_rounded : Icons.logout_rounded,
            onTap: state.isGuest
                ? () => showLoginDialog(context, state)
                : state.signOut,
          ),
        ], radius: AppRadius.none),
        const SizedBox(height: AppSpacing.md),
        _ActionRow(
          label: '刷新曲库',
          icon: Icons.refresh_rounded,
          onTap: () => unawaited(state.refreshHome(force: true)),
        ),
        const SizedBox(height: 24),
        const SectionHeading('外观'),
        const SizedBox(height: 12),
        DropdownButtonFormField<ThemeMode>(
          key: ValueKey(state.themeMode),
          initialValue: state.themeMode,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.tr('主题'),
            filled: true,
            fillColor: context.colors.ivoryLight,
            border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: context.borders.hairline,
            ),
          ),
          items: [
            for (final mode in ThemeMode.values)
              DropdownMenuItem(
                value: mode,
                child: Text(
                  mode == ThemeMode.system
                      ? context.tr('跟随系统')
                      : context.tr(mode == ThemeMode.light ? '浅色' : '深色'),
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) unawaited(state.setThemeMode(value));
          },
        ),
        const SizedBox(height: 24),
        const SectionHeading('语言'),
        const SizedBox(height: 12),
        DropdownButtonFormField<AppLanguage>(
          key: ValueKey(state.language),
          initialValue: state.language,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: context.tr('界面语言'),
            filled: true,
            fillColor: context.colors.ivoryLight,
            border: const OutlineInputBorder(borderRadius: BorderRadius.zero),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.zero,
              borderSide: context.borders.hairline,
            ),
          ),
          items: [
            for (final language in AppLanguage.values)
              DropdownMenuItem(
                value: language,
                child: Text(
                  language == AppLanguage.system
                      ? context.tr(language.name)
                      : language.name,
                ),
              ),
          ],
          onChanged: (value) {
            if (value != null) unawaited(state.setLanguage(value));
          },
        ),
        const SizedBox(height: 24),
        const SectionHeading('交互'),
        SquareSwitchListTile(
          title: const TrText('震动反馈'),
          subtitle: const TrText('点击可操作的元素和拖动进度条时反馈'),
          value: state.hapticsEnabled,
          onChanged: (value) => unawaited(state.setHapticsEnabled(value)),
        ),
        if (defaultTargetPlatform == TargetPlatform.iOS) ...[
          TrText(
            '震动强度 · ${(state.hapticIntensity * 100).round()}%',
            style: context.type.bodySm,
          ),
          AccessibleSlider(
            semanticLabel: '震动强度',
            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
            value: state.hapticIntensity,
            divisions: 20,
            onChanged: state.hapticsEnabled
                ? (value) => unawaited(state.setHapticIntensity(value))
                : null,
            onChangeEnd: (_) => unawaited(state.feedback(boundary: true)),
          ),
        ],
        TrText(
          '歌词控件自动隐藏 · ${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
          style: context.type.bodySm,
        ),
        AccessibleSlider(
          semanticLabel: '歌词控件自动隐藏时间',
          semanticFormatterCallback: (value) => '${value.toStringAsFixed(1)} 秒',
          value: state.lyricControlsSeconds,
          min: 1,
          max: 10,
          divisions: 18,
          label: '${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
          onChanged: (value) => unawaited(state.setLyricControlsSeconds(value)),
        ),
        const SizedBox(height: 16),
        const SectionHeading('歌词与滚动'),
        const SizedBox(height: 16),
        LyricTypographySetting(state: state),
        SquareSwitchListTile(
          title: const TrText('歌词模糊'),
          subtitle: const TrText('距离当前歌词越远，模糊越强；手动浏览时渐隐'),
          value: state.lyricBlurEnabled,
          onChanged: (value) => unawaited(state.setLyricBlurEnabled(value)),
        ),
        ScrollInertiaSetting(state: state),
        TrText(
          '手动浏览后恢复跟随 · ${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
          style: context.type.bodySm,
        ),
        AccessibleSlider(
          semanticLabel: '恢复歌词自动跟随时间',
          semanticFormatterCallback: (value) => '${value.toStringAsFixed(1)} 秒',
          value: state.lyricResumeSeconds,
          min: 1,
          max: 10,
          divisions: 18,
          label: '${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
          onChanged: (value) => unawaited(state.setLyricResumeSeconds(value)),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Me — the signed-in field notebook: profile, liked songs, own collections
// ---------------------------------------------------------------------------

/// The "我" section. Guests get a single login invitation on the parchment;
/// a signed-in session shows the profile header, the personal liked
/// collection, and the playlists the account created or subscribed to —
/// all straight from the gateway, never fabricated.
class _MeView extends StatefulWidget {
  const _MeView({required this.state});

  final AppState state;

  @override
  State<_MeView> createState() => _MeViewState();
}

class _MeViewState extends State<_MeView> {
  UserCollections _collections = UserCollections.empty;
  bool _loading = false;
  String? _error;
  int _uid = 0;

  @override
  void initState() {
    super.initState();
    _uid = widget.state.user.userId;
    if (_uid > 0) unawaited(_load(_uid));
  }

  @override
  void didUpdateWidget(covariant _MeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Signing in or out while this page is open swaps the notebook.
    final int uid = widget.state.user.userId;
    if (uid != _uid) {
      _uid = uid;
      _collections = UserCollections.empty;
      if (uid > 0) {
        unawaited(_load(uid));
      } else {
        setState(() {
          _collections = UserCollections.empty;
          _loading = false;
          _error = null;
        });
      }
    }
  }

  Future<void> _load(int uid, {bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (force) await widget.state.catalog.invalidateCollections(uid);
      final UserCollections collections = await widget.state.userCollections();
      if (!mounted || _uid != uid) return;
      setState(() {
        _collections = collections;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || _uid != uid) return;
      setState(() {
        _loading = false;
        _error = '歌单加载失败，请检查网络后重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final SessionUser user = widget.state.user;
    if (user.isGuest) return _guest();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: AppSpacing.section * 0.5),
        _profileCard(user),
        if (MediaQuery.sizeOf(context).width < _compactBreakpoint) ...[
          const SizedBox(height: AppSpacing.md),
          _likedEntry(),
        ],
        const SizedBox(height: AppSpacing.section * 0.6),
        _collectionsSection(),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
  // -- guest ----------------------------------------------------------------

  Widget _likedEntry() {
    final liked = _collections.liked ?? widget.state.collections.liked;
    return PaperCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        key: const ValueKey('mobile-liked-playlist'),
        onTap: _loading && liked == null
            ? null
            : () async {
                if (liked != null) {
                  _openPlaylist(context, widget.state, liked);
                  return;
                }
                await _load(_uid, force: true);
                if (!mounted) return;
                final loaded = _collections.liked;
                if (loaded != null) {
                  _openPlaylist(context, widget.state, loaded);
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                color: context.colors.manilla,
                child: Icon(Icons.favorite_rounded, color: context.colors.clay),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TrText('我喜欢', style: context.type.subheading),
                    const SizedBox(height: 4),
                    TrText(
                      liked == null
                          ? (_loading ? '正在同步歌单…' : '暂无歌单')
                          : '${liked.trackCount} 首',
                      style: context.type.captionMuted,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.colors.cloudDark,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _guest() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _HeroHeading(title: '我的音乐', body: '登录后，自己的歌单都会出现在这里。'),
        const SizedBox(height: AppSpacing.section * 0.5),
        PaperCard(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const InlineLabel('账户'),
              const SizedBox(height: AppSpacing.sm),
              TrText(
                '还没有登录',
                style: context.type.subheading.copyWith(fontSize: 22),
              ),
              const SizedBox(height: 6),
              TrText(
                '支持二维码、短信、密码或 Cookie 登录。',
                style: context.type.body.copyWith(
                  color: context.colors.cloudDark,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              ClayButton(
                label: '登录网易云账户',
                onPressed: () => showLoginDialog(context, widget.state),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  Widget _profileCard(SessionUser user) {
    final String? vip = user.vipLabel;
    // A manilla disc carries the avatar; without one, the initial stands in —
    // the same glyph treatment as the sidebar user card.
    final Widget avatar = SizedBox(
      width: 64,
      height: 64,
      child: (user.avatarUrl ?? '').isEmpty
          ? Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.colors.manilla,
                shape: BoxShape.rectangle,
              ),
              child: Text(
                (user.isGuest ? context.tr(user.name) : user.name)
                    .characters
                    .first,
                style: context.type.heading.copyWith(fontSize: 26, height: 1),
              ),
            )
          : PlateArt(
              seed: user.userId,
              coverUrl: user.avatarUrl,
              radius: BorderRadius.zero,
            ),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final mobile = MediaQuery.sizeOf(context).width < 720;
        final signOut = TextButton.icon(
          onPressed: widget.state.signOut,
          icon: const Icon(Icons.logout_rounded, size: 18),
          label: const TrText('退出登录'),
          style: TextButton.styleFrom(
            foregroundColor: context.colors.slateDark,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        );
        if (mobile) {
          return PaperCard(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 12,
              children: [avatar, signOut],
            ),
          );
        }
        return PaperCard(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              avatar,
              SizedBox(
                width: (box.maxWidth - 360).clamp(180.0, 500.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.isGuest ? context.tr(user.name) : user.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.subheading.copyWith(
                              fontSize: 22,
                            ),
                          ),
                        ),
                        if (vip != null) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.colors.oatWarm,
                              borderRadius: BorderRadius.zero,
                            ),
                            child: TrText(
                              vip,
                              style: context.type.caption.copyWith(
                                color: context.colors.clayDeep,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      user.handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionMuted,
                    ),
                  ],
                ),
              ),
              signOut,
            ],
          ),
        );
      },
    );
  }

  Widget _collectionsSection() {
    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _EmptyHint(
            icon: Icons.cloud_off_outlined,
            title: '歌单暂时不可用',
            body: _error!,
          ),
          const SizedBox(height: AppSpacing.md),
          IvoryButton(
            label: '重新加载',
            onPressed: () => unawaited(_load(_uid, force: true)),
          ),
        ],
      );
    }
    if (_loading &&
        _collections.created.isEmpty &&
        _collections.subscribed.isEmpty) {
      return const _EmptyHint(
        icon: Icons.library_music_outlined,
        title: '正在加载歌单',
        body: '从你的账户读取我创建和我收藏的歌单。',
      );
    }
    final List<Widget> sections = <Widget>[];
    void addShelf(String label, List<Playlist> playlists) {
      if (sections.isNotEmpty) {
        sections.add(const SizedBox(height: AppSpacing.section * 0.6));
      }
      sections.add(SectionHeading('$label · ${playlists.length}'));
      sections.add(const SizedBox(height: AppSpacing.md));
      sections.add(
        playlists.isEmpty
            ? TrText('还没有歌单。', style: context.type.captionMuted)
            : _PlaylistGrid(playlists: playlists, state: widget.state),
      );
    }

    addShelf('我创建的歌单', _collections.created);
    addShelf('我收藏的歌单', _collections.subscribed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: sections,
    );
  }
}

/// A tappable settings row (sign-out): slate type, hairline chevron, oat
/// tint on hover.
class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: feedbackAction(context, widget.onTap),
        child: AnimatedContainer(
          duration: _hovering
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          color: _hovering
              ? context.colors.oatWarm.withValues(alpha: 0.5)
              : context.colors.oatWarm.withValues(alpha: 0),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 14,
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16, color: context.colors.slateDark),
              const SizedBox(width: 10),
              Expanded(
                child: TrText(
                  widget.label,
                  style: context.type.bodySm.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: context.colors.cloudMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One catalogue row: index / cover, serif title, artist, album, duration,
/// and a hover-revealed play control.
class TrackRow extends StatelessWidget {
  const TrackRow({
    super.key,
    this.state,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.onPlay,
  });

  final AppState? state;
  final Track track;
  final int index;
  final bool isCurrent;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return _TrackRowBody(
      state: state,
      track: track,
      index: index,
      isCurrent: isCurrent,
      onPlay: onPlay,
    );
  }
}

class _TrackRowBody extends StatefulWidget {
  const _TrackRowBody({
    this.state,
    required this.track,
    required this.index,
    required this.isCurrent,
    required this.onPlay,
  });

  final AppState? state;
  final Track track;
  final int index;
  final bool isCurrent;
  final VoidCallback onPlay;

  @override
  State<_TrackRowBody> createState() => _TrackRowBodyState();
}

class _TrackRowBodyState extends State<_TrackRowBody> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Track track = widget.track;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: feedbackAction(context, widget.onPlay),
        child: AnimatedContainer(
          duration: _hovering
              ? const Duration(milliseconds: 120)
              : Duration.zero,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.zero,
            color: widget.isCurrent
                ? context.colors.oatWarm.withValues(alpha: 0.5)
                : _hovering
                ? context.colors.oatWarm.withValues(alpha: 0.35)
                : context.colors.oatWarm.withValues(alpha: 0),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 12,
          ),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              // Album is the first column to go when the row narrows —
              // mobile lists and search results keep title/artist intact.
              final bool showAlbum = c.maxWidth > 520;
              return Row(
                children: [
                  SizedBox(
                    width:
                        (widget.index.toString().length.clamp(2, 9) *
                                MediaQuery.textScalerOf(context).scale(7.5))
                            .clamp(24.0, 140.0),
                    child: _hovering
                        ? Icon(
                            Icons.play_arrow_rounded,
                            size: 18,
                            color: context.colors.slateDark,
                          )
                        : Text(
                            widget.index.toString().padLeft(2, '0'),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.monoSm,
                          ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: PlateArt(
                      seed: track.coverSeed,
                      coverUrl: track.coverUrl,
                      accent: track.accent,
                      radius: BorderRadius.zero,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.type.body.copyWith(
                            fontSize: 16,
                            height: 1.3,
                            fontWeight: widget.isCurrent
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                        if (widget.state != null)
                          ArtistNameLink(
                            state: widget.state!,
                            artists: track.artists,
                            fallback: track.artist,
                            style: context.type.captionMuted,
                          )
                        else
                          Text(
                            track.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.captionMuted,
                          ),
                        if (track.translatedTitle?.isNotEmpty ?? false)
                          Text(
                            track.translatedTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.type.captionMuted,
                          ),
                      ],
                    ),
                  ),
                  if (showAlbum) ...[
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: widget.state != null
                          ? AlbumNameLink(
                              state: widget.state!,
                              track: track,
                              style: context.type.captionMuted,
                            )
                          : Text(
                              track.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.type.caption.copyWith(
                                color: context.colors.cloudDark,
                              ),
                            ),
                    ),
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  Text(fmt(track.duration), style: context.type.monoSm),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Player bar — desktop keeps the dark footer slab (inversion); the compact
// shell swaps it for a floating ivory note-card above the tab bar.
// ---------------------------------------------------------------------------

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({
    required this.state,
    required this.onExpand,
    this.compact = false,
    this.includeBottomSafeArea = false,
  });

  final AppState state;
  final VoidCallback onExpand;

  /// True in the narrow shell: swaps the full transport row for the
  /// compact prev / play / next cluster.
  final bool compact;
  final bool includeBottomSafeArea;

  /// Narrow shell: transport controls floating straight on the parchment —
  /// no card, no slab; a clay progress hairline runs along the bottom edge
  /// (tap or drag to seek).
  Widget _compactTransport(BuildContext context, Track? track) {
    return Row(
      children: [
        Expanded(
          child: track == null
              ? TrText('未选择曲目', style: context.type.captionMuted)
              : MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: feedbackAction(context, onExpand),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 42,
                          height: 42,
                          child: PlateArt(
                            seed: track.coverSeed,
                            coverUrl: track.coverUrl,
                            accent: track.accent,
                            radius: BorderRadius.zero,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm + 2),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                track.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.type.body.copyWith(
                                  fontSize: 15,
                                  height: 1.25,
                                ),
                              ),
                              Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.type.captionMuted,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        const SizedBox(width: AppSpacing.xs),
        _LightIconButton(
          icon: Icons.skip_previous_rounded,
          tooltip: '上一首',
          enabled: track != null,
          onTap: track == null ? null : state.previous,
        ),
        const SizedBox(width: 2),
        _LightPlayButton(
          playing: state.playing,
          enabled: track != null,
          onTap: state.togglePlay,
        ),
        const SizedBox(width: 2),
        _LightIconButton(
          icon: Icons.skip_next_rounded,
          tooltip: '下一首',
          enabled: track != null,
          onTap: track == null ? null : state.next,
        ),
      ],
    );
  }

  /// The progress hairline along the bottom edge — the mobile seek control
  /// (tap anywhere, or drag along it).
  Widget _compactProgress(Track? track) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        void seekAt(double dx) {
          if (track == null || box.maxWidth <= 0) return;
          state.seek((dx / box.maxWidth).clamp(0.0, 1.0));
        }

        final double fraction = track == null ? 0 : state.progress;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (TapDownDetails d) => seekAt(d.localPosition.dx),
          onHorizontalDragUpdate: (DragUpdateDetails d) =>
              seekAt(d.localPosition.dx),
          child: SizedBox(
            height: AppSpacing.sm + 4,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(height: 2, color: context.colors.stone),
                ),
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: Container(
                    height: 2,
                    width: box.maxWidth * fraction,
                    color: context.colors.clay,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Floating compact transport: controls and a progress hairline only —
  /// no card, no fill; the page scrolls underneath.
  Widget _compactSurface(BuildContext context, Track? track) {
    return Material(
      color: context.colors.ivoryLight,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: context.borders.hairline),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
              child: _compactTransport(context, track),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _compactProgress(track),
            ),
            if (includeBottomSafeArea)
              SizedBox(height: MediaQuery.paddingOf(context).bottom + 4),
            if (!includeBottomSafeArea) const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }

  /// Shared dark-surface chrome for the bar (both the full and compact
  /// layouts) so the transport strip only swaps its controls.
  Widget _surface(BuildContext context, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: context.colors.playerSurface,
        border: Border(top: BorderSide(color: context.colors.slateMedium)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Leaf transport surface: rebuilds on ticks (100 ms position) and on
    // structural changes. Kept deliberately narrow — nothing above it
    // listens to the tick lane anymore.
    return AnimatedBuilder(
      animation: state.all,
      builder: (BuildContext context, _) {
        final Track? track = state.current;
        if (compact) {
          return _compactSurface(context, track);
        }
        return _surface(
          context,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SeekSlider(state: state),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  // Left: cover + metadata, clickable to expand Now Playing.
                  Expanded(
                    flex: 3,
                    child: track == null
                        ? TrText(
                            '未选择曲目',
                            style: context.type.bodySm.copyWith(
                              color: context.colors.onDarkMuted,
                            ),
                          )
                        : MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              onTap: feedbackAction(context, onExpand),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: PlateArt(
                                      seed: track.coverSeed,
                                      coverUrl: track.coverUrl,
                                      accent: track.accent,
                                      radius: BorderRadius.zero,
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.md),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          track.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.type.body.copyWith(
                                            fontSize: 16,
                                            height: 1.25,
                                            color: context.colors.onDark,
                                          ),
                                        ),
                                        Text(
                                          track.artist,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: context.type.caption.copyWith(
                                            color: context.colors.onDarkMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Icon(
                                    Icons.expand_less_rounded,
                                    color: context.colors.onDarkMuted,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          ),
                  ),

                  // Center: transport controls. FittedBox keeps the cluster
                  // intact at narrow window widths instead of overflowing.
                  Expanded(
                    flex: 2,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _DarkIconButton(
                            icon: state.shuffle
                                ? Icons.shuffle_on_rounded
                                : Icons.shuffle_rounded,
                            active: state.shuffle,
                            tooltip: '随机播放',
                            onTap: state.toggleShuffle,
                          ),
                          const SizedBox(width: 6),
                          _DarkIconButton(
                            icon: Icons.skip_previous_rounded,
                            tooltip: '上一首',
                            size: 26,
                            onTap: track == null ? null : state.previous,
                          ),
                          const SizedBox(width: 6),
                          _PlayPauseButton(
                            playing: state.playing,
                            enabled: track != null,
                            onTap: state.togglePlay,
                          ),
                          const SizedBox(width: 6),
                          _DarkIconButton(
                            icon: Icons.skip_next_rounded,
                            tooltip: '下一首',
                            size: 26,
                            onTap: track == null ? null : state.next,
                          ),
                          const SizedBox(width: 6),
                          _DarkIconButton(
                            icon: state.repeat == LoopMode.one
                                ? Icons.repeat_one_on_rounded
                                : Icons.repeat_rounded,
                            active: state.repeat != LoopMode.off,
                            tooltip: '循环播放',
                            onTap: state.cycleRepeat,
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Right: volume, queue and time.
                  Expanded(
                    flex: 3,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (track != null &&
                            MediaQuery.sizeOf(context).width >= 1100)
                          Text(
                            '${fmt(state.position)} / ${fmt(track.duration)}',
                            style: context.type.monoSm.copyWith(
                              color: context.colors.onDarkMuted,
                            ),
                          ),
                        const SizedBox(width: AppSpacing.md),
                        Flexible(
                          child: VolumeControl(state: state, onDark: true),
                        ),
                        _DarkIconButton(
                          icon: Icons.queue_music_rounded,
                          tooltip: '播放队列 · ${state.queue.length} 首',
                          onTap: () => showPlaybackQueue(context, state),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Hairline seek bar. Track in Slate Medium, progress in ivory; the thumb is
/// a small clay disc — a functional accent on the one dark surface.
/// Light-surface siblings of the dark transport controls, used by the
/// compact (mobile) card: slate glyphs, hover shifts to clay.
class _LightIconButton extends StatefulWidget {
  const _LightIconButton({
    required this.icon,
    required this.enabled,
    this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  State<_LightIconButton> createState() => _LightIconButtonState();
}

class _LightIconButtonState extends State<_LightIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final Color color = !widget.enabled
        ? context.colors.stone
        : _hovering
        ? context.colors.clayDeep
        : context.colors.slateDark;
    Widget btn = MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 34,
          height: 38,
          child: Icon(widget.icon, size: 22, color: color),
        ),
      ),
    );
    if (widget.tooltip != null) {
      btn = AccessibleTooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}

/// Clay play/pause button — the compact card's single accent.
class _LightPlayButton extends StatefulWidget {
  const _LightPlayButton({
    required this.playing,
    required this.enabled,
    required this.onTap,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_LightPlayButton> createState() => _LightPlayButtonState();
}

class _LightPlayButtonState extends State<_LightPlayButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            shape: BoxShape.rectangle,
            color: widget.enabled
                ? (_hovering ? context.colors.clayDeep : context.colors.clay)
                : context.colors.stone,
          ),
          child: Icon(
            widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 24,
            color: widget.enabled
                ? context.colors.onDark
                : context.colors.cloudDark,
          ),
        ),
      ),
    );
  }
}

class _SeekSlider extends StatelessWidget {
  const _SeekSlider({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: 3,
          activeTrackColor: context.colors.onPlayer,
          inactiveTrackColor: context.colors.slateMedium,
          thumbColor: context.colors.clay,
          overlayColor: context.colors.clay.withValues(alpha: 0.18),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
        ),
        child: HapticSeekSlider(state: state),
      ),
    );
  }
}

class _DarkIconButton extends StatefulWidget {
  const _DarkIconButton({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
    this.size = 20,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  State<_DarkIconButton> createState() => _DarkIconButtonState();
}

class _DarkIconButtonState extends State<_DarkIconButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    Color color = !enabled
        ? context.colors.slateMedium
        : widget.active || _hovering
        ? context.colors.onDark
        : context.colors.onDarkMuted;
    final Widget icon = Icon(widget.icon, size: widget.size, color: color);
    final Widget btn = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(width: 36, height: 36, child: Center(child: icon)),
      ),
    );
    return widget.tooltip == null
        ? btn
        : AccessibleTooltip(message: widget.tooltip!, child: btn);
  }
}

class _PlayPauseButton extends StatefulWidget {
  const _PlayPauseButton({
    required this.playing,
    required this.enabled,
    required this.onTap,
  });

  final bool playing;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<_PlayPauseButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.rectangle,
            color: widget.enabled
                ? (_hovering
                      ? context.colors.manilla
                      : context.colors.ivoryLight)
                : context.colors.slateMedium,
          ),
          child: Icon(
            widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 26,
            color: widget.enabled
                ? context.colors.slateDark
                : context.colors.onDarkMuted,
          ),
        ),
      ),
    );
  }
}
