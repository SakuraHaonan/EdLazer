import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../data/catalog.dart';
import '../data/models.dart';
import '../l10n/app_language.dart';
import '../scrolling/scroll_motion.dart';
import '../state/app_state.dart';
import '../state/ui_preferences.dart';
import '../widgets/ui_scaling.dart';
import 'legacy_login.dart';
import 'legacy_theme.dart';
import 'legacy_widgets.dart';

/// Scroll padding shared by every legacy page.
const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(
  LegacyTokens.pagePadding,
  18,
  LegacyTokens.pagePadding,
  28,
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
          const SizedBox(height: 12),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              itemCount: rail.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (BuildContext context, int index) => LegacyPlaylistCard(
                playlist: rail[index],
                onTap: () => onOpenPlaylist(rail[index]),
              ),
            ),
          ),
          const SizedBox(height: 22),
        ],
        LegacySectionHeader(
          title: likedName ?? '继续播放',
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
    final double minScale = UiMetrics.minScaleOf(context);
    final double shownScale = UiMetrics.scaleOf(context);
    final bool car = UiMetrics.carOf(context);
    return ListView(
      padding: _pagePadding,
      children: [
        Text('设置', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 5),
        Text(
          '外观、界面和账户。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 22),
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
          label: '配色',
          subtitle: state.legacyPalette.detail,
          trailing: DropdownButton<LegacyPaletteMode>(
            value: state.legacyPalette,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(16),
            items: <DropdownMenuItem<LegacyPaletteMode>>[
              for (final LegacyPaletteMode mode in LegacyPaletteMode.values)
                DropdownMenuItem<LegacyPaletteMode>(
                  value: mode,
                  child: Text(mode.label),
                ),
            ],
            onChanged: (LegacyPaletteMode? value) {
              if (value != null) unawaited(state.setLegacyPalette(value));
            },
          ),
        ),
        _LegacySettingRow(
          label: '设备形态',
          subtitle: state.surface.detail,
          trailing: DropdownButton<AppSurface>(
            value: state.surface,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(16),
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
            borderRadius: BorderRadius.circular(16),
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
          divisions: ((kDpiScaleMax - minScale) / kDpiScaleStep).round(),
          onChanged: (double value) => unawaited(state.setDpiScale(value)),
          action: TextButton(
            onPressed: () => unawaited(state.resetDpiScale()),
            child: const Text('恢复默认'),
          ),
        ),
        _LegacySwitchRow(
          label: '自动调节 DPI 缩放',
          subtitle: '按窗口可用空间自动推算',
          value: state.autoDpiScale,
          onChanged: (bool value) => unawaited(state.setAutoDpiScale(value)),
        ),
        _LegacySettingRow(
          label: '背景',
          subtitle: '使用当前歌曲封面主色渲染整页画布',
          trailing: DropdownButton<LegacyBackgroundMode>(
            value: state.legacyBackground,
            underline: const SizedBox.shrink(),
            borderRadius: BorderRadius.circular(16),
            items: <DropdownMenuItem<LegacyBackgroundMode>>[
              for (final LegacyBackgroundMode mode in LegacyBackgroundMode.values)
                DropdownMenuItem<LegacyBackgroundMode>(
                  value: mode,
                  child: Text(mode.label),
                ),
            ],
            onChanged: (LegacyBackgroundMode? value) {
              if (value != null) unawaited(state.setLegacyBackground(value));
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
          onChanged: state.legacyBackground == LegacyBackgroundMode.off
              ? null
              : (double value) => unawaited(state.setLegacyUiAlpha(value)),
        ),
        const _LegacySectionLabel('外观'),
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
        const _LegacySectionLabel('交互'),
        _LegacySwitchRow(
          label: '震动反馈',
          subtitle: '点击可操作的元素和拖动进度条、数值条时反馈',
          value: state.hapticsEnabled,
          onChanged: (bool value) => unawaited(state.setHapticsEnabled(value)),
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
                ? (double value) => unawaited(state.setHapticIntensity(value))
                : null,
          ),
        _LegacySliderRow(
          label: '歌词控件自动隐藏',
          valueText: '${state.lyricControlsSeconds.toStringAsFixed(1)} 秒',
          subtitle: '闲置一会儿后收起歌词页的控件',
          value: state.lyricControlsSeconds.clamp(1.0, 10.0),
          min: 1,
          max: 10,
          divisions: 18,
          onChanged: (double value) =>
              unawaited(state.setLyricControlsSeconds(value)),
        ),
        const _LegacySectionLabel('歌词'),
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
          onChanged: (bool value) => unawaited(state.setLyricBlurEnabled(value)),
        ),
        _LegacySliderRow(
          label: '手动浏览后恢复跟随',
          valueText: '${state.lyricResumeSeconds.toStringAsFixed(1)} 秒',
          subtitle: '松开手后多久回到当前行',
          value: state.lyricResumeSeconds.clamp(1.0, 10.0),
          min: 1,
          max: 10,
          divisions: 18,
          onChanged: (double value) =>
              unawaited(state.setLyricResumeSeconds(value)),
        ),
        const _LegacySectionLabel('滚动'),
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
            onPressed: () =>
                unawaited(state.setScrollRetention(ScrollMotion.defaultRetention)),
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
              state.setScrollAcceleration(ScrollMotion.defaultAcceleration),
            ),
            child: const Text('恢复默认'),
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
        _LegacySettingRow(
          label: '刷新曲库',
          subtitle: '重新拉取首页、歌单和每日推荐',
          trailing: OutlinedButton(
            onPressed: () => unawaited(state.refreshHome(force: true)),
            child: const Text('刷新'),
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
    // Narrow windows stack the control under its label instead of squeezing
    // both into one line.
    final bool stacked = MediaQuery.sizeOf(context).width < 560;
    final Widget heading = Column(
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
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 2),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            )
          : Row(
              children: [
                Expanded(child: heading),
                const SizedBox(width: 16),
                Flexible(child: trailing),
              ],
            ),
    );
  }
}

/// A settings row with a switch on the right.
class _LegacySwitchRow extends StatelessWidget {
  const _LegacySwitchRow({
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

/// A settings row whose control is a full-width slider under the label, with
/// the value on the right and an optional reset action.
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
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleMedium)),
              if (action != null) ...[action!, const SizedBox(width: 4)],
              Text(
                valueText,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// A settings row of mutually exclusive chips and the current value.
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
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.titleMedium)),
              Text(
                valueText,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final int choice in choices)
                ChoiceChip(
                  label: Text(
                    labelOf(choice),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.values[choice ~/ 100 - 1],
                    ),
                  ),
                  showCheckmark: false,
                  selected: selected == choice,
                  selectedColor: scheme.secondaryContainer,
                  backgroundColor: scheme.surfaceContainerHighest.withValues(
                    alpha: 0.45,
                  ),
                  side: BorderSide(
                    color: selected == choice
                        ? scheme.primary
                        : scheme.outlineVariant,
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
