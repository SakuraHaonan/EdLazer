import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
import '../interaction/app_haptics.dart';
import '../legacy/legacy_login.dart';
import '../lyrics/viewport.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../theme/apple_design.dart';
import '../utils/cover_save.dart';
import '../widgets/apple_ui.dart';
import '../widgets/interaction_feedback.dart';
import '../legacy/legacy_widgets.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/song_comments_view.dart';
import 'player_backdrop.dart';

enum _SidePanel { none, queue, comments }

enum NowPlayingMenuAction { saveCover, copyTitle, copyArtist, shortcuts }

/// The completely rebuilt adaptive now-playing page.
///
/// Desktop uses an artwork-led split composition; phones use a compact header
/// with a full-height lyric canvas. Both share one transport implementation,
/// one lyric viewport and one queue/comment stack.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.state,
    this.onClose,
    this.entranceSettled = true,
  });

  final AppState state;
  final VoidCallback? onClose;

  /// When the host is still animating the page in (or about to animate it
  /// out), expensive ambient blur/flow work is held back until the transition
  /// has finished.
  final bool entranceSettled;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  final FocusNode _focus = FocusNode(debugLabel: 'now-playing');
  _SidePanel _panel = _SidePanel.none;
  SongCommentsController? _comments;
  bool _fullscreen = false;
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_readFullscreen());
    _armControlsTimer();
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _comments?.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Bottom transport on the phone player yields to the lyric sheet after the
  /// listener stops touching it. Any tap, drag or panel brings it back and
  /// restarts the wait, whose length is the settings slider.
  void _revealControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _armControlsTimer();
  }

  void _armControlsTimer() {
    _controlsTimer?.cancel();
    final double seconds = state.lyricControlsSeconds;
    _controlsTimer = Timer(
      Duration(milliseconds: (seconds * 1000).round()),
      () {
        if (!mounted || _panel != _SidePanel.none) return;
        setState(() => _controlsVisible = false);
      },
    );
  }

  Future<void> _readFullscreen() async {
    try {
      final bool active = await windowManager.isFullScreen();
      if (mounted) setState(() => _fullscreen = active);
    } catch (_) {
      // The plugin is unavailable in tests and non-desktop embeddings.
    }
  }

  void _closePage() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).maybePop();
    }
  }

  void _closePanel() {
    if (_panel != _SidePanel.none) setState(() => _panel = _SidePanel.none);
    _armControlsTimer();
  }

  void _openPanel(_SidePanel panel) {
    if (_panel == panel) {
      _closePanel();
      return;
    }
    if (panel == _SidePanel.comments) {
      _comments ??= SongCommentsController(state.gateway);
    }
    _controlsTimer?.cancel();
    setState(() {
      _panel = panel;
      _controlsVisible = true;
    });
  }

  Future<void> _toggleFullscreen() async {
    try {
      await windowManager.setFullScreen(!_fullscreen);
      if (mounted) setState(() => _fullscreen = !_fullscreen);
    } catch (_) {}
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

  void _toggleLike() {
    unawaited(state.feedback());
    if (state.isGuest) {
      unawaited(showLegacyLoginDialog(context, state));
      return;
    }
    unawaited(state.toggleLikeCurrent());
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

  Future<void> _confirmSaveCover() async {
    final Track? track = state.current;
    final String? url = track?.coverUrl;
    if (track == null || url == null || url.isEmpty) return;
    unawaited(state.feedback());
    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('保存封面'),
        content: Text('是否保存「${track.title}」的封面？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (save == true) await _saveCover();
  }

  Future<void> _copy(String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _onMore(NowPlayingMenuAction action) {
    final Track? track = state.current;
    if (track == null) return;
    switch (action) {
      case NowPlayingMenuAction.saveCover:
        unawaited(_saveCover());
      case NowPlayingMenuAction.copyTitle:
        unawaited(_copy(track.title, '已复制歌曲名'));
      case NowPlayingMenuAction.copyArtist:
        unawaited(_copy(legacyArtistNames(track), '已复制歌手名'));
      case NowPlayingMenuAction.shortcuts:
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
            _ShortcutRow(keys: 'L', action: '喜欢当前歌曲'),
            _ShortcutRow(keys: 'Q', action: '播放队列'),
            _ShortcutRow(keys: 'C', action: '评论'),
            _ShortcutRow(keys: 'F', action: '全屏'),
            _ShortcutRow(keys: 'Esc', action: '关闭面板或播放器'),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('知道了'),
        ),
      ],
    ),
  );

  ThemeData _playerTheme() {
    final ThemeData base = buildAppleTheme(
      brightness: Brightness.dark,
      seedAccent: AppleColors.musicRed,
    );
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: Colors.white,
        onPrimary: Colors.black,
        secondary: AppleColors.musicRed,
        onSecondary: Colors.white,
      ),
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _playerTheme(),
      child: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, Widget? _) {
          final Track? track = state.current;
          final double width = MediaQuery.sizeOf(context).width;
          final bool wide = width >= 840;
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
                  _openPanel(_SidePanel.queue),
              const SingleActivator(LogicalKeyboardKey.keyC): () =>
                  _openPanel(_SidePanel.comments),
              const SingleActivator(LogicalKeyboardKey.keyF): () =>
                  unawaited(_toggleFullscreen()),
              const SingleActivator(LogicalKeyboardKey.escape): () {
                if (_panel != _SidePanel.none) {
                  _closePanel();
                } else {
                  _closePage();
                }
              },
            },
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              child: Scaffold(
                backgroundColor: Colors.black,
                body: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    AlbumBlurFlow(
                      track: track,
                      mode: state.legacyBackground,
                      pageColor: Colors.black,
                      animationsEnabled: widget.entranceSettled,
                    ),
                    SafeArea(
                      child: track == null
                          ? _empty(context)
                          : wide
                          ? KeyedSubtree(
                              key: const ValueKey<String>(
                                'desktop-now-playing',
                              ),
                              child: _desktop(context, track),
                            )
                          : KeyedSubtree(
                              key: const ValueKey<String>('mobile-now-playing'),
                              child: _mobile(context, track),
                            ),
                    ),
                    if (track != null && _panel != _SidePanel.none)
                      wide
                          ? _desktopPanel(context, track)
                          : _mobilePanel(context, track),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.music_note_rounded,
            size: 44,
            color: Color(0x99FFFFFF),
          ),
          const SizedBox(height: 14),
          const Text(
            '还没有播放中的曲目。',
            style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 15),
          ),
          const SizedBox(height: 18),
          IconButton(
            tooltip: '关闭',
            onPressed: _closePage,
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
          ),
        ],
      ),
    );
  }

  Widget _desktop(BuildContext context, Track track) {
    return Column(
      children: <Widget>[
        _desktopTopBar(context, track),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(26, 8, 26, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(flex: 40, child: _desktopInfo(track)),
                const SizedBox(width: 24),
                Expanded(flex: 60, child: _lyricsPane(compact: false)),
              ],
            ),
          ),
        ),
        _DesktopTransport(state: state),
      ],
    );
  }

  Widget _mobile(BuildContext context, Track track) {
    final Size size = MediaQuery.sizeOf(context);
    final bool landscape = size.width > size.height;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _revealControls(),
      child: Column(
        children: <Widget>[
          _mobileTopBar(context, track, landscape: landscape),
            Expanded(
            child: landscape
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                    child: LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                            // The row must be told its height. Without it the
                            // info card sizes from its own content and grows
                            // past a short landscape screen, pushing the
                            // transport below the visible edge.
                            return SizedBox(
                              height: constraints.maxHeight,
                              child: Row(
                                children: <Widget>[
                                  Expanded(
                                    flex: 40,
                                    child: _mobileInfoCard(track),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    flex: 60,
                                    child: _lyricsPane(compact: true),
                                  ),
                                ],
                              ),
                            );
                          },
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
                    child: Column(
                      children: <Widget>[
                        _compactHeader(context, track),
                        const SizedBox(height: 8),
                        Expanded(child: _lyricsPane(compact: true)),
                      ],
                    ),
                  ),
          ),
          // Keep the transport mounted so its key survives the hide, but report
          // no height while collapsed. A height factor of zero only clips: the
          // child is still measured at full size past the screen edge.
          _Collapsible(
            collapsed: !_controlsVisible,
            child: AnimatedOpacity(
              key: const ValueKey<String>('mobile-transport-visibility'),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              opacity: _controlsVisible ? 1 : 0,
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _MobileTransport(
                  state: state,
                  landscape: landscape,
                  onOpenPanel: _openPanel,
                  onInteract: _revealControls,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _desktopTopBar(BuildContext context, Track track) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 18, 4),
      child: Row(
        children: <Widget>[
          _TopIconButton(
            key: const ValueKey<String>('desktop-close'),
            tooltip: '收起播放器 (Esc)',
            icon: Icons.keyboard_arrow_down_rounded,
            onPressed: _closePage,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  '正在播放',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.25,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  track.album.isEmpty ? legacyArtistNames(track) : track.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          _TopIconButton(
            key: const ValueKey<String>('desktop-comments'),
            tooltip: '评论 (C)',
            icon: Icons.mode_comment_outlined,
            selected: _panel == _SidePanel.comments,
            onPressed: () => _openPanel(_SidePanel.comments),
          ),
          _TopIconButton(
            key: const ValueKey<String>('desktop-queue'),
            tooltip: '播放队列 (Q)',
            icon: Icons.queue_music_rounded,
            selected: _panel == _SidePanel.queue,
            onPressed: () => _openPanel(_SidePanel.queue),
          ),
          _TopIconButton(
            key: const ValueKey<String>('desktop-fullscreen'),
            tooltip: _fullscreen ? '退出全屏 (F)' : '全屏 (F)',
            icon: _fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            onPressed: () => unawaited(_toggleFullscreen()),
          ),
          _MoreButton(
            key: const ValueKey<String>('desktop-more'),
            includeShortcuts: true,
            onSelected: _onMore,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _desktopInfo(Track track) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double cover = math
            .min(
              constraints.maxWidth * .92,
              math.max(160, constraints.maxHeight - 224),
            )
            .clamp(160.0, 390.0)
            .toDouble();
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => unawaited(_confirmSaveCover()),
                  child: _Artwork(
                    track: track,
                    size: cover,
                    radius: 10,
                    iconSize: cover * .14,
                  ),
                ),
                SizedBox(height: constraints.maxHeight < 620 ? 16 : 22),
                Text(
                  track.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 26,
                    height: 1.18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.4,
                    color: Colors.white,
                    shadows: <Shadow>[
                      Shadow(
                        color: Color(0x99000000),
                        blurRadius: 18,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
                if (track.translatedTitle?.trim().isNotEmpty ??
                    false) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    track.translatedTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xB3FFFFFF),
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
                    fontSize: 16,
                    height: 1.3,
                    color: Color(0xB3FFFFFF),
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    _TopIconButton(
                      key: const ValueKey<String>('desktop-like'),
                      tooltip: state.currentLiked ? '取消收藏 (L)' : '收藏 (L)',
                      icon: state.currentLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      selected: state.currentLiked,
                      onPressed: _toggleLike,
                    ),
                    _TopIconButton(
                      tooltip: '保存封面',
                      icon: Icons.download_rounded,
                      onPressed: () => unawaited(_saveCover()),
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

  Widget _lyricsPane({required bool compact}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? 14 : 18, 6, 10, 2),
          child: Row(
            children: <Widget>[
              const Text(
                '歌词',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                  color: Color(0x66FFFFFF),
                ),
              ),
              const SizedBox(width: 8),
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
          child: compact
              ? LyricViewport(
                  state: state,
                  blurEnabled: widget.entranceSettled ? null : false,
                )
              : LyricViewport(
                  state: state,
                  fontSize: 26,
                  fontWeight: 600,
                  blurEnabled: false,
                ),
        ),
      ],
    );
  }

  Widget _mobileTopBar(
    BuildContext context,
    Track track, {
    required bool landscape,
  }) {
    return SizedBox(
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          children: <Widget>[
            _TopIconButton(
              key: const ValueKey<String>('mobile-close'),
              tooltip: '收起播放器',
              icon: Icons.keyboard_arrow_down_rounded,
              onPressed: _closePage,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text(
                      '正在播放',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    if (landscape)
                      Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0x80FFFFFF),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (landscape) ...<Widget>[
              _TopIconButton(
                key: const ValueKey<String>('mobile-queue'),
                tooltip: '播放队列',
                icon: Icons.queue_music_rounded,
                onPressed: () {
                  final AppState? feedback = InteractionFeedback.of(context);
                  if (feedback != null) unawaited(feedback.feedback());
                  _openPanel(_SidePanel.queue);
                },
              ),
              TextButton.icon(
                key: const ValueKey<String>('mobile-comments'),
                onPressed: feedbackAction(
                  context,
                  () => _openPanel(_SidePanel.comments),
                ),
                icon: const Icon(Icons.mode_comment_outlined, size: 17),
                label: const Text('查看评论'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xB3FFFFFF),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 40),
                  textStyle: const TextStyle(fontSize: 13),
                ),
              ),
            ],
            _TopIconButton(
              key: const ValueKey<String>('mobile-like'),
              tooltip: state.currentLiked ? '取消喜欢' : '加入喜欢',
              icon: state.currentLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              selected: state.currentLiked,
              onPressed: _toggleLike,
            ),
            _MoreButton(
              key: const ValueKey<String>('mobile-more'),
              onSelected: _onMore,
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }

  Widget _compactHeader(BuildContext context, Track track) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: <Widget>[
          GestureDetector(
            key: const ValueKey<String>('legacy-now-playing-cover'),
            behavior: HitTestBehavior.opaque,
            onLongPress: () => unawaited(_confirmSaveCover()),
            child: _Artwork(track: track, size: 56, radius: 8, iconSize: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                if (track.translatedTitle?.trim().isNotEmpty ?? false)
                  Text(
                    track.translatedTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                Text(
                  legacyArtistNames(track),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileInfoCard(Track track) {
    return AppleGlass(
      borderRadius: BorderRadius.circular(18),
      blurSigma: 24,
      color: Colors.white.withValues(alpha: .08),
      border: Border.all(color: Colors.white.withValues(alpha: .12), width: .5),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          // An unbounded height (a scroll view, or a row that has not been
          // given one) must not fall through to the 180 px ceiling: that makes
          // the card report a height taller than a landscape phone, and the
          // transport below it is pushed past the screen edge.
          final double available = constraints.maxHeight.isFinite
              ? constraints.maxHeight - 86
              : constraints.maxWidth - 34;
          final double side = math
              .min(constraints.maxWidth - 34, available)
              .clamp(50.0, 180.0);
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onLongPress: () => unawaited(_confirmSaveCover()),
                    child: _Artwork(
                      track: track,
                      size: side,
                      radius: 12,
                      iconSize: 26,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    legacyArtistNames(track),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0x99FFFFFF),
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

  Widget _desktopPanel(BuildContext context, Track track) {
    final double width = math.min(430, MediaQuery.sizeOf(context).width * .38);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closePanel,
            child: ColoredBox(color: Colors.black.withValues(alpha: .32)),
          ),
          Positioned(
            top: 66,
            right: 16,
            bottom: 16,
            width: width,
            child: AppleGlass(
              borderRadius: BorderRadius.circular(20),
              blurSigma: 30,
              color: const Color(0xF21C1C1E),
              border: Border.all(
                color: Colors.white.withValues(alpha: .12),
                width: .5,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  children: <Widget>[
                    SizedBox(
                      height: 48,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                _panel == _SidePanel.queue ? '播放队列' : '评论',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey<String>(
                                'desktop-panel-close',
                              ),
                              tooltip: '关闭',
                              onPressed: _closePanel,
                              icon: const Icon(Icons.close_rounded, size: 19),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: .5, color: Color(0x33FFFFFF)),
                    Expanded(
                      child: _panel == _SidePanel.queue
                          ? PlaybackQueueView(state: state, showHeader: false)
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
        ],
      ),
    );
  }

  Widget _mobilePanel(BuildContext context, Track track) {
    final Size size = MediaQuery.sizeOf(context);
    final bool reduce = MediaQuery.disableAnimationsOf(context);
    return Positioned.fill(
      child: Stack(
        children: <Widget>[
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _closePanel,
            child: ColoredBox(color: Colors.black.withValues(alpha: .36)),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: reduce
                  ? Duration.zero
                  : const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (BuildContext context, double value, Widget? child) {
                return Transform.translate(
                  offset: Offset(0, (1 - value) * 36),
                  child: Opacity(opacity: value, child: child),
                );
              },
              child: SafeArea(
                top: false,
                child: Container(
                  height: size.height * .92,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1C1C1E),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(20),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: <Widget>[
                      SizedBox(
                        height: 50,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 2, 6, 2),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  _panel == _SidePanel.queue ? '播放队列' : '评论',
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey<String>(
                                  'mobile-panel-close',
                                ),
                                tooltip: '关闭',
                                onPressed: _closePanel,
                                icon: const Icon(Icons.close_rounded, size: 19),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Divider(height: .5, color: Color(0x33FFFFFF)),
                      Expanded(
                        child: _panel == _SidePanel.queue
                            ? PlaybackQueueView(state: state, showHeader: false)
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

class _TopIconButton extends StatelessWidget {
  const _TopIconButton({
    super.key,
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
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.secondary;
    return IconButton(
      tooltip: tooltip,
      onPressed: feedbackAction(context, onPressed),
      iconSize: 20,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      style: IconButton.styleFrom(
        foregroundColor: selected ? accent : const Color(0xB3FFFFFF),
        backgroundColor: selected
            ? accent.withValues(alpha: .14)
            : Colors.transparent,
        shape: const CircleBorder(),
      ),
      icon: Icon(icon),
    );
  }
}

class _MoreButton extends StatelessWidget {
  const _MoreButton({
    super.key,
    required this.onSelected,
    this.includeShortcuts = false,
  });

  final ValueChanged<NowPlayingMenuAction> onSelected;
  final bool includeShortcuts;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<NowPlayingMenuAction>(
      tooltip: '更多',
      onOpened: () {
        final AppState? state = InteractionFeedback.of(context);
        if (state != null) unawaited(state.feedback());
      },
      onSelected: (NowPlayingMenuAction action) {
        final AppState? state = InteractionFeedback.of(context);
        if (state != null) unawaited(state.feedback());
        onSelected(action);
      },
      color: const Color(0xFF1C1C1E),
      surfaceTintColor: Colors.transparent,
      elevation: 18,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      icon: const Icon(
        Icons.more_horiz_rounded,
        color: Color(0xB3FFFFFF),
        size: 22,
      ),
      itemBuilder: (BuildContext context) =>
          <PopupMenuEntry<NowPlayingMenuAction>>[
            const PopupMenuItem<NowPlayingMenuAction>(
              value: NowPlayingMenuAction.saveCover,
              child: _MenuRow(icon: Icons.download_rounded, label: '保存封面'),
            ),
            const PopupMenuItem<NowPlayingMenuAction>(
              value: NowPlayingMenuAction.copyTitle,
              child: _MenuRow(icon: Icons.copy_rounded, label: '复制歌曲名'),
            ),
            const PopupMenuItem<NowPlayingMenuAction>(
              value: NowPlayingMenuAction.copyArtist,
              child: _MenuRow(
                icon: Icons.person_outline_rounded,
                label: '复制歌手名',
              ),
            ),
            if (includeShortcuts)
              const PopupMenuItem<NowPlayingMenuAction>(
                value: NowPlayingMenuAction.shortcuts,
                child: _MenuRow(
                  icon: Icons.keyboard_alt_outlined,
                  label: '键盘快捷键',
                ),
              ),
          ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 17, color: const Color(0xB3FFFFFF)),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.track,
    required this.size,
    required this.radius,
    required this.iconSize,
  });

  final Track track;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      image: true,
      label: '${track.title} 封面',
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x8A000000),
              blurRadius: 36,
              offset: Offset(0, 15),
            ),
          ],
          border: Border.all(color: const Color(0x14FFFFFF), width: .5),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox.square(
            dimension: size,
            child: LegacyCover(
              url: track.coverUrl,
              radius: 0,
              iconSize: iconSize,
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.action});

  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Text(
              keys,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xB3FFFFFF),
              ),
            ),
          ),
          Expanded(
            child: Text(
              action,
              style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF)),
            ),
          ),
        ],
      ),
    );
  }
}

class _DesktopTransport extends StatefulWidget {
  const _DesktopTransport({required this.state});

  final AppState state;

  @override
  State<_DesktopTransport> createState() => _DesktopTransportState();
}

class _DesktopTransportState extends State<_DesktopTransport> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withValues(alpha: .26),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedBuilder(
              animation: widget.state.ticks,
              builder: (BuildContext context, Widget? _) => _seekRow(),
            ),
            const SizedBox(height: 1),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 280,
                  child: Text(
                    widget.state.queue.isEmpty
                        ? ''
                        : '${widget.state.queueIndex + 1} / ${widget.state.queue.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0x66FFFFFF),
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                Expanded(
                  child: Center(
                    child: _TransportControls(
                      state: widget.state,
                      compact: false,
                    ),
                  ),
                ),
                SizedBox(
                  width: 280,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      IconButton(
                        tooltip: widget.state.volume <= .001 ? '取消静音' : '静音',
                        onPressed: feedbackAction(
                          context,
                          () => unawaited(widget.state.toggleMute()),
                        ),
                        iconSize: 19,
                        color: const Color(0xB3FFFFFF),
                        icon: Icon(
                          widget.state.volume <= .001
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                        ),
                      ),
                      SizedBox(
                        width: 96,
                        child: Slider(
                          value: widget.state.volume.clamp(0.0, 1.0),
                          onChanged: (double value) =>
                              unawaited(widget.state.setVolume(value)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _seekRow() {
    final Track? track = widget.state.current;
    final Duration duration = track?.duration ?? Duration.zero;
    final double live = duration.inMilliseconds <= 0
        ? 0
        : (widget.state.precisePosition.inMilliseconds /
                  duration.inMilliseconds)
              .clamp(0.0, 1.0);
    final double fraction = (_drag ?? live).clamp(0.0, 1.0);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 62,
          child: _TimeLabel(
            legacyDuration(
              Duration(
                milliseconds: (duration.inMilliseconds * fraction).round(),
              ),
            ),
            align: TextAlign.start,
          ),
        ),
        Expanded(
          child: Semantics(
            key: const ValueKey<String>('desktop-seek-semantics'),
            container: true,
            slider: true,
            label: '播放进度',
            value:
                '${legacyDuration(Duration(milliseconds: (duration.inMilliseconds * fraction).round()))} / ${legacyDuration(duration)}',
            increasedValue: '+1%',
            decreasedValue: '-1%',
            onIncrease: () =>
                widget.state.seek((fraction + .01).clamp(0.0, 1.0)),
            onDecrease: () =>
                widget.state.seek((fraction - .01).clamp(0.0, 1.0)),
            child: ExcludeSemantics(
              child: PlayerSeekBar(
                key: const ValueKey<String>('desktop-seek-bar'),
                progress: fraction,
                buffered: widget.state.bufferedFraction,
                debugPrefix: 'desktop',
                onPreview: (double value) => setState(() => _drag = value),
                onCommit: (double value) {
                  setState(() => _drag = null);
                  widget.state.seek(value);
                },
                onCancel: () => setState(() => _drag = null),
                feedback: widget.state.feedback,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 62,
          child: _TimeLabel(legacyDuration(duration), align: TextAlign.end),
        ),
      ],
    );
  }
}

/// Reports the child's height while open and nothing while collapsed, without
/// unmounting it. The child is still laid out, but its box is clipped to the
/// reported size so a hidden transport cannot extend past the screen.
class _Collapsible extends SingleChildRenderObjectWidget {
  const _Collapsible({required this.collapsed, required super.child});

  final bool collapsed;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderCollapsible(collapsed);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCollapsible renderObject,
  ) {
    renderObject.collapsed = collapsed;
  }
}

class _RenderCollapsible extends RenderProxyBox {
  _RenderCollapsible(this._collapsed);

  bool _collapsed;

  bool get collapsed => _collapsed;

  set collapsed(bool value) {
    if (_collapsed == value) return;
    _collapsed = value;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _collapsed ? 0 : super.computeMinIntrinsicHeight(width);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _collapsed ? 0 : super.computeMaxIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    if (_collapsed) return Size(constraints.maxWidth, 0);
    return child?.getDryLayout(constraints) ?? Size.zero;
  }

  @override
  void performLayout() {
    final RenderBox? current = child;
    if (current == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    current.layout(constraints, parentUsesSize: true);
    size = _collapsed
        ? constraints.constrain(Size(current.size.width, 0))
        : constraints.constrain(current.size);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (_collapsed) return false;
    return super.hitTestChildren(result, position: position);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_collapsed) return;
    super.paint(context, offset);
  }
}

class _MobileTransport extends StatefulWidget {
  const _MobileTransport({
    required this.state,
    required this.landscape,
    required this.onOpenPanel,
    required this.onInteract,
  });

  final AppState state;
  final bool landscape;
  final ValueChanged<_SidePanel> onOpenPanel;
  final VoidCallback onInteract;

  @override
  State<_MobileTransport> createState() => _MobileTransportState();
}

class _MobileTransportState extends State<_MobileTransport> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Container(
        key: const ValueKey<String>('now-playing-transport'),
        decoration: BoxDecoration(
          color: apple.glassStrong,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: .12),
            width: .5,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .28),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        padding: EdgeInsets.fromLTRB(
          12,
          widget.landscape ? 6 : 8,
          12,
          widget.landscape ? 4 : 7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!widget.landscape) ...<Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: TextButton.icon(
                      key: const ValueKey<String>('mobile-queue'),
                      onPressed: feedbackAction(
                        context,
                        () => widget.onOpenPanel(_SidePanel.queue),
                      ),
                      icon: const Icon(Icons.queue_music_rounded, size: 17),
                      label: const Text('播放队列'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xB3FFFFFF),
                        backgroundColor: Colors.white.withValues(alpha: .08),
                        minimumSize: const Size(0, 38),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextButton.icon(
                      key: const ValueKey<String>('mobile-comments'),
                      onPressed: feedbackAction(
                        context,
                        () => widget.onOpenPanel(_SidePanel.comments),
                      ),
                      icon: const Icon(Icons.mode_comment_outlined, size: 17),
                      label: const Text('查看评论'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xB3FFFFFF),
                        backgroundColor: Colors.white.withValues(alpha: .08),
                        minimumSize: const Size(0, 38),
                        shape: const StadiumBorder(),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
            ],
            AnimatedBuilder(
              animation: widget.state.ticks,
              builder: (BuildContext context, Widget? _) => _seekRow(),
            ),
            SizedBox(height: widget.landscape ? 1 : 2),
            _TransportControls(state: widget.state, compact: true),
            if ((widget.state.playbackError ?? widget.state.likeError)
                case final String issue when issue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  issue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: scheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _seekRow() {
    final Track? track = widget.state.current;
    final Duration duration = track?.duration ?? Duration.zero;
    final double live = duration.inMilliseconds <= 0
        ? 0
        : (widget.state.precisePosition.inMilliseconds /
                  duration.inMilliseconds)
              .clamp(0.0, 1.0);
    final double fraction = (_drag ?? live).clamp(0.0, 1.0);
    return Row(
      children: <Widget>[
        SizedBox(
          width: widget.landscape ? 34 : 40,
          child: _TimeLabel(
            legacyDuration(
              Duration(
                milliseconds: (duration.inMilliseconds * fraction).round(),
              ),
            ),
            align: TextAlign.start,
          ),
        ),
        Expanded(
          child: Semantics(
            key: const ValueKey<String>('now-playing-seek-semantics'),
            container: true,
            slider: true,
            label: '播放进度',
            value:
                '${legacyDuration(Duration(milliseconds: (duration.inMilliseconds * fraction).round()))} / ${legacyDuration(duration)}',
            increasedValue: '+1%',
            decreasedValue: '-1%',
            onIncrease: () =>
                widget.state.seek((fraction + .01).clamp(0.0, 1.0)),
            onDecrease: () =>
                widget.state.seek((fraction - .01).clamp(0.0, 1.0)),
            child: ExcludeSemantics(
              child: PlayerSeekBar(
                key: ValueKey<String>('now-playing-seek-${track?.id}'),
                progress: fraction,
                buffered: widget.state.bufferedFraction,
                debugPrefix: 'now-playing',
                height: widget.landscape ? 26 : 30,
                onPreview: (double value) {
                  widget.onInteract();
                  setState(() => _drag = value);
                },
                onCommit: (double value) {
                  widget.onInteract();
                  setState(() => _drag = null);
                  widget.state.seek(value);
                },
                onCancel: () {
                  widget.onInteract();
                  setState(() => _drag = null);
                },
                feedback: widget.state.feedback,
              ),
            ),
          ),
        ),
        SizedBox(
          width: widget.landscape ? 34 : 40,
          child: _TimeLabel(legacyDuration(duration), align: TextAlign.end),
        ),
      ],
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({required this.state, required this.compact});

  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final double side = compact ? 38 : 44;
    final double play = compact ? 48 : 54;
    final double glyph = compact ? 21 : 25;
    final IconData repeatIcon = switch (state.repeat) {
      LoopMode.off => Icons.repeat_rounded,
      LoopMode.all => Icons.repeat_on_rounded,
      LoopMode.one => Icons.repeat_one_on_rounded,
    };
    final String repeatTip = switch (state.repeat) {
      LoopMode.off => '顺序播放',
      LoopMode.all => '列表循环',
      LoopMode.one => '单曲循环',
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _TransportIcon(
          tooltip: '随机播放',
          icon: Icons.shuffle_rounded,
          selected: state.shuffle,
          size: side,
          iconSize: compact ? 18 : 20,
          onPressed: state.toggleShuffle,
        ),
        const SizedBox(width: 2),
        _TransportIcon(
          tooltip: '上一首',
          icon: Icons.skip_previous_rounded,
          size: side,
          iconSize: glyph,
          onPressed: state.current == null ? null : state.previous,
        ),
        const SizedBox(width: 2),
        IconButton(
          key: const ValueKey<String>('now-playing-play'),
          tooltip: state.playing ? '暂停' : '播放',
          onPressed: state.current == null
              ? null
              : feedbackAction(context, state.togglePlay),
          iconSize: compact ? 25 : 28,
          style: IconButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white.withValues(alpha: .16),
            disabledForegroundColor: Colors.black38,
            fixedSize: Size.square(play),
            minimumSize: Size.square(play),
            maximumSize: Size.square(play),
            shape: const CircleBorder(),
          ),
          icon: Icon(
            state.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
        ),
        const SizedBox(width: 2),
        _TransportIcon(
          tooltip: '下一首',
          icon: Icons.skip_next_rounded,
          size: side,
          iconSize: glyph,
          onPressed: state.current == null ? null : state.next,
        ),
        const SizedBox(width: 2),
        _TransportIcon(
          tooltip: repeatTip,
          icon: repeatIcon,
          selected: state.repeat != LoopMode.off,
          size: side,
          iconSize: compact ? 18 : 20,
          onPressed: state.cycleRepeat,
        ),
      ],
    );
  }
}

class _TransportIcon extends StatelessWidget {
  const _TransportIcon({
    required this.tooltip,
    required this.icon,
    required this.size,
    required this.iconSize,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final double size;
  final double iconSize;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final Color accent = Theme.of(context).colorScheme.secondary;
    return IconButton(
      tooltip: tooltip,
      onPressed: feedbackAction(context, onPressed),
      iconSize: iconSize,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      style: IconButton.styleFrom(
        foregroundColor: selected ? accent : const Color(0xB3FFFFFF),
        disabledForegroundColor: const Color(0x42FFFFFF),
      ),
      icon: Icon(icon),
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel(this.text, {required this.align});

  final String text;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: const TextStyle(
        fontSize: 10.5,
        color: Color(0x66FFFFFF),
        fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}

class PlayerSeekBar extends StatefulWidget {
  const PlayerSeekBar({
    super.key,
    required this.progress,
    required this.buffered,
    required this.debugPrefix,
    required this.onPreview,
    required this.onCommit,
    required this.onCancel,
    this.feedback,
    this.height = 30,
  });

  final double progress;
  final double buffered;
  final String debugPrefix;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;
  final VoidCallback onCancel;

  /// Detent ticks while the thumb moves, so dragging feels like a notched dial.
  final Future<void> Function({bool detent, bool boundary})? feedback;
  final double height;

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  double? _hover;
  double? _drag;
  final SeekDetents _detents = SeekDetents();

  void _tick(double value, {required bool grabbed}) {
    final Future<void> Function({bool detent, bool boundary})? feedback =
        widget.feedback;
    if (feedback == null) return;
    if (grabbed) {
      _detents.begin(value);
      unawaited(feedback(detent: true));
      return;
    }
    if (_detents.update(value)) {
      unawaited(
        feedback(detent: true, boundary: value <= 0 || value >= 1),
      );
    }
  }

  double _fractionAt(double dx, double width) =>
      width <= 0 ? 0 : (dx / width).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double played = (_drag ?? widget.progress).clamp(0.0, 1.0);
        // Hovering only enlarges the thumb; it must not preview the seek
        // position, so the thumb stays on the real playback progress until a
        // tap or drag starts.
        final double thumbFraction = (_drag ?? played).clamp(0.0, 1.0);
        const double thumbSlot = 12;
        final double travel = math.max(0, width - thumbSlot);
        final double trackTop = widget.height / 2 - 1.5;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onHover: (PointerHoverEvent event) => setState(
            () => _hover = _fractionAt(event.localPosition.dx, width),
          ),
          onExit: (_) => setState(() => _hover = null),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (TapDownDetails details) {
              final double value = _fractionAt(details.localPosition.dx, width);
              setState(() => _drag = value);
              _tick(value, grabbed: true);
              widget.onPreview(value);
            },
            onTapUp: (TapUpDetails details) {
              final double value = _fractionAt(details.localPosition.dx, width);
              setState(() => _drag = null);
              _detents.end();
              widget.onCommit(value);
            },
            onHorizontalDragStart: (DragStartDetails details) {
              final double value = _fractionAt(details.localPosition.dx, width);
              setState(() => _drag = value);
              _tick(value, grabbed: true);
              widget.onPreview(value);
            },
            onHorizontalDragUpdate: (DragUpdateDetails details) {
              final double value = _fractionAt(details.localPosition.dx, width);
              setState(() => _drag = value);
              _tick(value, grabbed: false);
              widget.onPreview(value);
            },
            onHorizontalDragEnd: (_) {
              final double value = _drag ?? played;
              setState(() => _drag = null);
              _detents.end();
              widget.onCommit(value);
            },
            onHorizontalDragCancel: () {
              setState(() => _drag = null);
              _detents.end();
              widget.onCancel();
            },
            child: SizedBox(
              height: widget.height,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: 0,
                    right: 0,
                    top: trackTop,
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .22),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width * widget.buffered.clamp(0.0, 1.0),
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: .16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width * played,
                    child: Container(
                      key: ValueKey<String>(
                        '${widget.debugPrefix}-seek-played',
                      ),
                      height: 3,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  Positioned(
                    left: travel * thumbFraction,
                    top: (widget.height - thumbSlot) / 2,
                    width: thumbSlot,
                    height: thumbSlot,
                    child: Center(
                      child: AnimatedContainer(
                        key: ValueKey<String>(
                          '${widget.debugPrefix}-seek-thumb',
                        ),
                        duration: const Duration(milliseconds: 120),
                        width: _hover != null || _drag != null ? 12 : 8,
                        height: _hover != null || _drag != null ? 12 : 8,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
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
