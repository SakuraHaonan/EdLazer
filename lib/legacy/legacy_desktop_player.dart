import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../theme/tokens.dart';
import '../utils/cover_save.dart';
import '../widgets/lyric_viewport.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/song_comments_view.dart';
import 'apple_music_theme.dart';
import 'legacy_background.dart';
import 'legacy_login.dart';
import 'legacy_widgets.dart';

/// The desktop now-playing page, in an Apple Music-inspired immersive style.
///
/// The page is deliberately a local exception to the app's Material 3 theme:
/// a blurred enlargement of the current artwork fills the window, the big
/// cover and centred track facts sit on the left, the lyric sheet floats on
/// the right without a card, and the transport is a transparent strip of white
/// controls with the Apple Music red reserved for the like state.
///
/// Interaction follows a desktop player rather than a phone: queue and comments
/// dock as a right-hand panel, the seek rail previews on hover and commits on
/// release, volume is always visible, and Space / arrows / M / L / Q / C / F
/// work without a modifier.
class LegacyDesktopNowPlaying extends StatefulWidget {
  const LegacyDesktopNowPlaying({
    super.key,
    required this.state,
    required this.onClose,
  });

  final AppState state;
  final VoidCallback onClose;

  @override
  State<LegacyDesktopNowPlaying> createState() =>
      _LegacyDesktopNowPlayingState();
}

enum _Panel { none, queue, comments }

enum _MoreAction { saveCover, copyTitle, copyArtist, shortcuts }

class _LegacyDesktopNowPlayingState extends State<LegacyDesktopNowPlaying> {
  static final ThemeData _theme = buildAppleMusicTheme();

  final FocusNode _focus = FocusNode(debugLabel: 'apple-music-now-playing');
  _Panel _panel = _Panel.none;
  SongCommentsController? _comments;
  bool _fullscreen = false;

  AppState get state => widget.state;

  /// Apple Music shows larger lyrics than the app's default 22 px; the page
  /// keeps the user's relative size preference and adds four points.
  double get _lyricSize => (state.lyricFontSize + 4).clamp(20.0, 44.0);

  late final ThemeData _lyricTheme = _theme.copyWith(
    colorScheme: _theme.colorScheme.copyWith(
      primary: AppleMusicColors.accent,
      onPrimary: Colors.white,
      onSurface: AppleMusicColors.textPrimary,
      // Apple Music's inactive lyrics are readable but clearly behind the
      // current line; the blurred artwork makes 40% too faint.
      onSurfaceVariant: const Color(0x99FFFFFF),
    ),
    textTheme: _theme.textTheme.copyWith(
      bodyLarge: _theme.textTheme.bodyLarge?.copyWith(
        shadows: const <Shadow>[
          Shadow(
            color: Color(0x99000000),
            blurRadius: 16,
            offset: Offset(0, 1),
          ),
        ],
      ),
      bodyMedium: _theme.textTheme.bodyMedium?.copyWith(
        shadows: const <Shadow>[
          Shadow(
            color: Color(0x99000000),
            blurRadius: 14,
            offset: Offset(0, 1),
          ),
        ],
      ),
    ),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_syncFullscreen());
  }

  Future<void> _syncFullscreen() async {
    try {
      final bool value = await windowManager.isFullScreen();
      if (mounted) setState(() => _fullscreen = value);
    } catch (_) {
      // Plugin unavailable (tests, web-like embeddings) — the button is inert.
    }
  }

  @override
  void dispose() {
    _comments?.dispose();
    _focus.dispose();
    super.dispose();
  }

  // -- actions --------------------------------------------------------------

  void _toggleLike() {
    unawaited(state.feedback());
    if (state.isGuest) {
      unawaited(showLegacyLoginDialog(context, state));
      return;
    }
    unawaited(state.toggleLikeCurrent());
  }

  void _seekBy(Duration delta) {
    final Track? track = state.current;
    if (track == null || track.duration <= Duration.zero) return;
    final int target = (state.precisePosition + delta).inMilliseconds.clamp(
      0,
      track.duration.inMilliseconds,
    );
    state.seek(target / track.duration.inMilliseconds);
  }

  Future<void> _toggleFullscreen() async {
    try {
      await windowManager.setFullScreen(!_fullscreen);
      if (mounted) setState(() => _fullscreen = !_fullscreen);
    } catch (_) {
      // Ignore: the backend may not expose fullscreen in this embedding.
    }
  }

  void _openPanel(_Panel panel) {
    if (_panel == panel) {
      setState(() => _panel = _Panel.none);
      return;
    }
    if (panel == _Panel.comments) {
      _comments ??= SongCommentsController(state.gateway);
    }
    setState(() => _panel = panel);
  }

  void _closePanel() {
    if (_panel != _Panel.none) setState(() => _panel = _Panel.none);
  }

  Future<void> _saveCover() async {
    final Track? track = state.current;
    final String? url = track?.coverUrl;
    if (track == null || url == null || url.isEmpty) return;
    final bool saved = await saveCover(url, track.title);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(saved ? '封面已保存' : '封面保存失败，请稍后重试')));
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _handleMore(_MoreAction action) {
    final Track? track = state.current;
    if (track == null) return;
    switch (action) {
      case _MoreAction.saveCover:
        unawaited(_saveCover());
      case _MoreAction.copyTitle:
        unawaited(_copy(track.title, '已复制歌曲名'));
      case _MoreAction.copyArtist:
        unawaited(_copy(legacyArtistNames(track), '已复制歌手名'));
      case _MoreAction.shortcuts:
        unawaited(_showShortcuts());
    }
  }

  Future<void> _showShortcuts() => showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('键盘快捷键'),
      content: const SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _ShortcutRow(keys: '空格', action: '播放 / 暂停'),
            _ShortcutRow(keys: '← / →', action: '后退 / 前进 5 秒'),
            _ShortcutRow(keys: 'Shift + ← / →', action: '后退 / 前进 15 秒'),
            _ShortcutRow(keys: '↑ / ↓', action: '音量 + / - 5%'),
            _ShortcutRow(keys: 'M', action: '静音'),
            _ShortcutRow(keys: 'L', action: '收藏当前歌曲'),
            _ShortcutRow(keys: 'Q', action: '播放队列'),
            _ShortcutRow(keys: 'C', action: '评论'),
            _ShortcutRow(keys: 'F', action: '全屏'),
            _ShortcutRow(keys: 'Esc', action: '关闭面板或收起播放器'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  // -- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _theme,
      child: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) {
          final Track? current = state.current;
          return CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.space): state.togglePlay,
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _seekBy(const Duration(seconds: -5)),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _seekBy(const Duration(seconds: 5)),
              const SingleActivator(
                LogicalKeyboardKey.arrowLeft,
                shift: true,
              ): () =>
                  _seekBy(const Duration(seconds: -15)),
              const SingleActivator(
                LogicalKeyboardKey.arrowRight,
                shift: true,
              ): () =>
                  _seekBy(const Duration(seconds: 15)),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  unawaited(
                    state.setVolume((state.volume + .05).clamp(0.0, 1.0)),
                  ),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  unawaited(
                    state.setVolume((state.volume - .05).clamp(0.0, 1.0)),
                  ),
              const SingleActivator(LogicalKeyboardKey.keyM): () =>
                  unawaited(state.toggleMute()),
              const SingleActivator(LogicalKeyboardKey.keyL): _toggleLike,
              const SingleActivator(LogicalKeyboardKey.keyQ): () =>
                  _openPanel(_Panel.queue),
              const SingleActivator(LogicalKeyboardKey.keyC): () =>
                  _openPanel(_Panel.comments),
              const SingleActivator(LogicalKeyboardKey.keyF): () =>
                  unawaited(_toggleFullscreen()),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_panel != _Panel.none) {
                  _closePanel();
                } else {
                  widget.onClose();
                }
              },
            },
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              child: Scaffold(
                key: const ValueKey<String>('desktop-now-playing'),
                backgroundColor: Colors.transparent,
                body: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    AlbumBlurFlow(
                      track: current,
                      mode: state.legacyBackground,
                      pageColor: AppleMusicColors.background,
                    ),
                    SafeArea(
                      top: false,
                      child: Column(
                        children: <Widget>[
                          _topBar(current),
                          Expanded(
                            child: current == null
                                ? const Center(
                                    child: Text(
                                      '还没有播放中的曲目。',
                                      style: TextStyle(
                                        color: AppleMusicColors.textSecondary,
                                      ),
                                    ),
                                  )
                                : _body(current),
                          ),
                          _transport(),
                        ],
                      ),
                    ),
                    if (_panel != _Panel.none) _panelOverlay(current),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _topBar(Track? track) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 22, 4),
      child: Row(
        children: <Widget>[
          _PlainIconButton(
            key: const ValueKey<String>('desktop-close'),
            tooltip: '收起播放器 (Esc)',
            icon: Icons.keyboard_arrow_down_rounded,
            size: 30,
            onPressed: widget.onClose,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  '正在播放',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                if (track != null)
                  Text(
                    track.album.isEmpty
                        ? legacyArtistNames(track)
                        : track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppleMusicColors.textPrimary,
                    ),
                  ),
              ],
            ),
          ),
          if (track != null) ...<Widget>[
            _PlainIconButton(
              key: const ValueKey<String>('desktop-comments'),
              tooltip: '评论 (C)',
              icon: Icons.mode_comment_outlined,
              selected: _panel == _Panel.comments,
              onPressed: () => _openPanel(_Panel.comments),
            ),
            _PlainIconButton(
              key: const ValueKey<String>('desktop-queue'),
              tooltip: '播放队列 (Q)',
              icon: Icons.queue_music_rounded,
              selected: _panel == _Panel.queue,
              onPressed: () => _openPanel(_Panel.queue),
            ),
            _PlainIconButton(
              key: const ValueKey<String>('desktop-fullscreen'),
              tooltip: _fullscreen ? '退出全屏 (F)' : '全屏 (F)',
              icon: _fullscreen
                  ? Icons.fullscreen_exit_rounded
                  : Icons.fullscreen_rounded,
              onPressed: () => unawaited(_toggleFullscreen()),
            ),
            PopupMenuButton<_MoreAction>(
              key: const ValueKey<String>('desktop-more'),
              tooltip: '更多',
              icon: const Icon(
                Icons.more_horiz_rounded,
                size: 22,
                color: AppleMusicColors.textSecondary,
              ),
              onSelected: _handleMore,
              itemBuilder: (BuildContext context) =>
                  <PopupMenuEntry<_MoreAction>>[
                    const PopupMenuItem<_MoreAction>(
                      value: _MoreAction.saveCover,
                      child: _MenuRow(
                        icon: Icons.download_rounded,
                        label: '保存封面',
                      ),
                    ),
                    const PopupMenuItem<_MoreAction>(
                      value: _MoreAction.copyTitle,
                      child: _MenuRow(
                        icon: Icons.content_copy_rounded,
                        label: '复制歌曲名',
                      ),
                    ),
                    const PopupMenuItem<_MoreAction>(
                      value: _MoreAction.copyArtist,
                      child: _MenuRow(
                        icon: Icons.person_outline_rounded,
                        label: '复制歌手名',
                      ),
                    ),
                    const PopupMenuDivider(),
                    const PopupMenuItem<_MoreAction>(
                      value: _MoreAction.shortcuts,
                      child: _MenuRow(
                        icon: Icons.keyboard_alt_outlined,
                        label: '键盘快捷键',
                      ),
                    ),
                  ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(Track track) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 22, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 42,
            child: _InfoPane(
              track: track,
              state: state,
              onLike: _toggleLike,
              onSaveCover: () => unawaited(_saveCover()),
              onMore: _handleMore,
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 58,
            child: _LyricsPane(
              state: state,
              lyricTheme: _lyricTheme,
              size: _lyricSize,
            ),
          ),
        ],
      ),
    );
  }

  Widget _transport() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppleMusicColors.hairline)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0x00000000), Color(0x99000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AnimatedBuilder(
            animation: state.ticks,
            builder: (BuildContext context, _) {
              final Track? track = state.current;
              final Duration duration = track?.duration ?? Duration.zero;
              final double live = duration.inMilliseconds <= 0
                  ? 0
                  : (state.precisePosition.inMilliseconds /
                            duration.inMilliseconds)
                        .clamp(0.0, 1.0);
              final _SeekGesture gesture = _seekGesture;
              final double fraction = (gesture.drag ?? live).clamp(0.0, 1.0);
              final String elapsed = legacyDuration(
                Duration(
                  milliseconds: (duration.inMilliseconds * fraction).round(),
                ),
              );
              return Row(
                children: <Widget>[
                  SizedBox(
                    width: 64,
                    child: Text(
                      elapsed,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppleMusicColors.textTertiary,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: _DesktopSeekBar(
                      key: const ValueKey<String>('desktop-seek-bar'),
                      progress: fraction,
                      buffered: state.bufferedFraction,
                      duration: duration,
                      onPreview: _previewSeek,
                      onCommit: _commitSeek,
                      onCancel: _cancelSeek,
                    ),
                  ),
                  SizedBox(
                    width: 64,
                    child: Text(
                      legacyDuration(duration),
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppleMusicColors.textTertiary,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 2),
          Row(
            children: <Widget>[
              SizedBox(
                width: 300,
                child: Text(
                  state.queue.isEmpty
                      ? ''
                      : '${state.queueIndex + 1} / ${state.queue.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppleMusicColors.textTertiary,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _PlainIconButton(
                      tooltip: '随机播放',
                      icon: Icons.shuffle_rounded,
                      selected: state.shuffle,
                      onPressed: state.toggleShuffle,
                    ),
                    const SizedBox(width: 6),
                    _PlainIconButton(
                      tooltip: '上一首',
                      icon: Icons.skip_previous_rounded,
                      size: 48,
                      iconSize: 26,
                      onPressed: state.previous,
                    ),
                    const SizedBox(width: 6),
                    _ApplePlayButton(
                      playing: state.playing,
                      onPressed: state.togglePlay,
                    ),
                    const SizedBox(width: 6),
                    _PlainIconButton(
                      tooltip: '下一首',
                      icon: Icons.skip_next_rounded,
                      size: 48,
                      iconSize: 26,
                      onPressed: state.next,
                    ),
                    const SizedBox(width: 6),
                    _PlainIconButton(
                      tooltip: switch (state.repeat) {
                        LoopMode.off => '顺序播放',
                        LoopMode.all => '列表循环',
                        LoopMode.one => '单曲循环',
                      },
                      icon: switch (state.repeat) {
                        LoopMode.off => Icons.repeat_rounded,
                        LoopMode.all => Icons.repeat_on_rounded,
                        LoopMode.one => Icons.repeat_one_on_rounded,
                      },
                      selected: state.repeat != LoopMode.off,
                      onPressed: state.cycleRepeat,
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 300,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    _DesktopVolume(state: state),
                    const SizedBox(width: 4),
                    _PlainIconButton(
                      tooltip: '播放队列 (Q)',
                      icon: Icons.queue_music_rounded,
                      selected: _panel == _Panel.queue,
                      onPressed: () => _openPanel(_Panel.queue),
                    ),
                    _PlainIconButton(
                      tooltip: _fullscreen ? '退出全屏 (F)' : '全屏 (F)',
                      icon: _fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      onPressed: () => unawaited(_toggleFullscreen()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -- seek preview ---------------------------------------------------------

  _SeekGesture _seekGesture = const _SeekGesture();

  void _previewSeek(double value) {
    setState(() => _seekGesture = _SeekGesture(drag: value));
  }

  void _commitSeek(double value) {
    setState(() => _seekGesture = const _SeekGesture());
    state.seek(value);
  }

  void _cancelSeek() {
    setState(() => _seekGesture = const _SeekGesture());
  }

  // -- panels ---------------------------------------------------------------

  Widget _panelOverlay(Track? track) {
    final Size size = MediaQuery.sizeOf(context);
    final double width = math.min(420, size.width * .37);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          GestureDetector(
            onTap: _closePanel,
            child: ColoredBox(color: Colors.black.withValues(alpha: .32)),
          ),
          Positioned(
            top: 14,
            right: 18,
            bottom: 132,
            width: width,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              builder: (BuildContext context, double value, Widget? child) =>
                  Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset((1 - value) * 28, 0),
                      child: child,
                    ),
                  ),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: AppleMusicColors.panel,
                  borderRadius: BorderRadius.all(Radius.circular(14)),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                  child: Column(
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 10, 6, 8),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                _panel == _Panel.queue ? '播放队列' : '评论',
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  color: AppleMusicColors.textPrimary,
                                ),
                              ),
                            ),
                            _PlainIconButton(
                              key: const ValueKey<String>(
                                'desktop-panel-close',
                              ),
                              tooltip: '关闭',
                              icon: Icons.close_rounded,
                              onPressed: _closePanel,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: _panel == _Panel.queue
                            ? PlaybackQueueView(state: state, showHeader: false)
                            : track == null || _comments == null
                            ? const SizedBox.shrink()
                            : SongCommentsView(
                                state: state,
                                track: track,
                                controller: _comments!,
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SeekGesture {
  const _SeekGesture({this.drag});

  final double? drag;
}

class _InfoPane extends StatelessWidget {
  const _InfoPane({
    required this.track,
    required this.state,
    required this.onLike,
    required this.onSaveCover,
    required this.onMore,
  });

  final Track track;
  final AppState state;
  final VoidCallback onLike;
  final VoidCallback onSaveCover;
  final ValueChanged<_MoreAction> onMore;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxHeight < 620;
        final double side = math
            .min(
              constraints.maxWidth * .94,
              constraints.maxHeight - (compact ? 196 : 230),
            )
            .clamp(168.0, 390.0);
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _Artwork(track: track, size: side),
                SizedBox(height: compact ? 18 : 26),
                Tooltip(
                  message: track.title,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: compact ? 23 : 26,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: AppleMusicColors.textPrimary,
                      shadows: const <Shadow>[
                        Shadow(
                          color: Color(0x99000000),
                          blurRadius: 16,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                if (!compact &&
                    (track.translatedTitle?.trim().isNotEmpty ??
                        false)) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    track.translatedTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppleMusicColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 7),
                Text(
                  legacyArtistNames(track),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.3,
                    color: AppleMusicColors.textSecondary,
                  ),
                ),
                if (!compact && track.album.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppleMusicColors.textTertiary,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _PlainIconButton(
                      key: const ValueKey<String>('desktop-like'),
                      tooltip: state.currentLiked ? '取消收藏 (L)' : '收藏 (L)',
                      icon: state.currentLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: state.currentLiked
                          ? AppleMusicColors.accent
                          : AppleMusicColors.textSecondary,
                      onPressed: onLike,
                    ),
                    const SizedBox(width: 8),
                    _PlainIconButton(
                      tooltip: '保存封面',
                      icon: Icons.download_rounded,
                      onPressed: onSaveCover,
                    ),
                    const SizedBox(width: 8),
                    PopupMenuButton<_MoreAction>(
                      tooltip: '更多',
                      icon: const Icon(
                        Icons.more_horiz_rounded,
                        size: 22,
                        color: AppleMusicColors.textSecondary,
                      ),
                      onSelected: onMore,
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<_MoreAction>>[
                            const PopupMenuItem<_MoreAction>(
                              value: _MoreAction.copyTitle,
                              child: _MenuRow(
                                icon: Icons.content_copy_rounded,
                                label: '复制歌曲名',
                              ),
                            ),
                            const PopupMenuItem<_MoreAction>(
                              value: _MoreAction.copyArtist,
                              child: _MenuRow(
                                icon: Icons.person_outline_rounded,
                                label: '复制歌手名',
                              ),
                            ),
                            const PopupMenuItem<_MoreAction>(
                              value: _MoreAction.shortcuts,
                              child: _MenuRow(
                                icon: Icons.keyboard_alt_outlined,
                                label: '键盘快捷键',
                              ),
                            ),
                          ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({required this.track, required this.size});

  final Track track;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: '${track.title} 封面',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x80000000),
              blurRadius: 42,
              offset: Offset(0, 18),
            ),
          ],
          border: Border.all(color: const Color(0x14FFFFFF)),
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          child: SizedBox.square(
            dimension: size,
            child: LegacyCover(
              url: track.coverUrl,
              radius: 0,
              iconSize: size * .18,
            ),
          ),
        ),
      ),
    );
  }
}

class _LyricsPane extends StatelessWidget {
  const _LyricsPane({
    required this.state,
    required this.lyricTheme,
    required this.size,
  });

  final AppState state;
  final ThemeData lyricTheme;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
          child: Row(
            children: <Widget>[
              const Text(
                '歌词',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: AppleMusicColors.textTertiary,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                state.lyricsLoading
                    ? '加载中'
                    : state.lyrics.isEmpty
                    ? '暂无歌词'
                    : '${state.lyrics.length} 行',
                style: const TextStyle(fontSize: 11, color: Color(0x4DFFFFFF)),
              ),
            ],
          ),
        ),
        Expanded(
          child: Theme(
            data: lyricTheme,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: LyricViewport(
                state: state,
                fontSize: size,
                fontWeight: 600,
                blurEnabled: false,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DesktopVolume extends StatefulWidget {
  const _DesktopVolume({required this.state});

  final AppState state;

  @override
  State<_DesktopVolume> createState() => _DesktopVolumeState();
}

class _DesktopVolumeState extends State<_DesktopVolume> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final double volume = (_drag ?? widget.state.volume).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _PlainIconButton(
          tooltip: volume <= .001 ? '取消静音' : '静音',
          icon: volume <= .001
              ? Icons.volume_off_rounded
              : volume < .5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
          iconSize: 19,
          onPressed: () => unawaited(widget.state.toggleMute()),
        ),
        SizedBox(
          width: 88,
          child: Slider(
            value: volume,
            semanticFormatterCallback: (double value) =>
                '音量 ${(value * 100).round()}%',
            onChanged: (double value) {
              setState(() => _drag = value);
              widget.state.previewVolume(value);
            },
            onChangeEnd: (double value) {
              setState(() => _drag = null);
              unawaited(widget.state.setVolume(value));
            },
          ),
        ),
      ],
    );
  }
}

class _ApplePlayButton extends StatelessWidget {
  const _ApplePlayButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: playing ? '暂停' : '播放',
      child: Material(
        color: AppleMusicColors.textPrimary,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 56,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 32,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlainIconButton extends StatelessWidget {
  const _PlainIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.iconSize = 21,
    this.size = 40,
    this.selected = false,
    this.color,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double iconSize;
  final double size;
  final bool selected;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: iconSize,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      style: IconButton.styleFrom(
        foregroundColor:
            color ??
            (selected
                ? AppleMusicColors.accent
                : AppleMusicColors.textSecondary),
        disabledForegroundColor: AppleMusicColors.textTertiary,
        highlightColor: Colors.transparent,
      ),
      icon: Icon(icon),
    );
  }
}

/// A desktop scrubber: a thin white rail with a hover thumb and a floating time
/// preview; dragging previews and the commit lands on release.
class _DesktopSeekBar extends StatefulWidget {
  const _DesktopSeekBar({
    super.key,
    required this.progress,
    required this.buffered,
    required this.duration,
    required this.onPreview,
    required this.onCommit,
    required this.onCancel,
  });

  final double progress;
  final double buffered;
  final Duration duration;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;

  @override
  State<_DesktopSeekBar> createState() => _DesktopSeekBarState();
}

class _DesktopSeekBarState extends State<_DesktopSeekBar> {
  double? _hover;
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        double fractionAt(double dx) =>
            width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);
        final double shown = (_drag ?? _hover ?? widget.progress).clamp(
          0.0,
          1.0,
        );
        final bool interacting = _drag != null;
        // Keep the thumb centred on the 3 dp rail and inside the track at both
        // ends. The old geometry put the 8 dp dot 3.5 dp above the rail and
        // hung half of it outside the left edge at 0:00.
        const double thumbSlot = 12;
        const double trackTop = 14.5;
        final double thumbSize = _hover == null && !interacting ? 8 : 12;
        final double thumbTravel = math.max(0.0, width - thumbSlot);
        final double thumbCenter = thumbTravel * shown + thumbSlot / 2;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (PointerHoverEvent event) => setState(
            () => _hover = interacting
                ? _hover
                : fractionAt(event.localPosition.dx),
          ),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails details) {
              final double value = fractionAt(details.localPosition.dx);
              widget.onPreview(value);
              widget.onCommit(value);
            },
            onHorizontalDragStart: (DragStartDetails details) {
              final double value = fractionAt(details.localPosition.dx);
              setState(() => _drag = value);
              widget.onPreview(value);
            },
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              final double value = fractionAt(details.localPosition.dx);
              setState(() => _drag = value);
              widget.onPreview(value);
            },
            onHorizontalDragEnd: (_) {
              final double? value = _drag;
              setState(() => _drag = null);
              if (value != null) widget.onCommit(value);
            },
            onHorizontalDragCancel: () {
              setState(() => _drag = null);
              widget.onCancel();
            },
            child: SizedBox(
              height: 32,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: trackTop,
                    child: Container(
                      height: 3,
                      decoration: const BoxDecoration(
                        color: Color(0x33FFFFFF),
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width * widget.buffered.clamp(0.0, 1.0),
                    child: Container(
                      height: 3,
                      decoration: const BoxDecoration(
                        color: Color(0x1FFFFFFF),
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width * shown,
                    child: Container(
                      height: 3,
                      decoration: const BoxDecoration(
                        color: AppleMusicColors.textPrimary,
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                  Positioned(
                    left: thumbTravel * shown,
                    top: (32 - thumbSlot) / 2,
                    width: thumbSlot,
                    height: thumbSlot,
                    child: Center(
                      child: AnimatedContainer(
                        key: const ValueKey<String>('desktop-seek-thumb'),
                        duration: AppMotion.instant,
                        width: thumbSize,
                        height: thumbSize,
                        decoration: const BoxDecoration(
                          color: AppleMusicColors.textPrimary,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  if (_hover != null && !interacting)
                    Positioned(
                      left: (thumbCenter - 34).clamp(0.0, width - 68),
                      top: -18,
                      child: _HoverTime(
                        label: legacyDuration(
                          Duration(
                            milliseconds:
                                (widget.duration.inMilliseconds * shown)
                                    .round(),
                          ),
                        ),
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
}

class _HoverTime extends StatelessWidget {
  const _HoverTime({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: 68,
        padding: const EdgeInsets.symmetric(vertical: 3),
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          color: AppleMusicColors.textPrimary,
          borderRadius: BorderRadius.all(Radius.circular(6)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: Colors.black,
            fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Icon(icon, size: 18, color: AppleMusicColors.textSecondary),
      const SizedBox(width: 12),
      Text(label),
    ],
  );
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Text(
              keys,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppleMusicColors.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: const TextStyle(
                fontSize: 13,
                color: AppleMusicColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
