import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../data/models.dart';
import 'player_backdrop.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../theme/app_palette.dart';
import '../theme/app_theme.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';
import '../utils/cover_save.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/animated_notice.dart';
import '../widgets/animated_track_cover.dart';
import '../widgets/catalog_links.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/lyric_viewport.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/song_comments_view.dart';
import 'desktop_now_playing.dart';

/// Shared comments entry from the player header.
Future<void> showSongComments(
  BuildContext context, {
  required AppState state,
  required Track track,
  required SongCommentsController controller,
}) async {
  final bool compact = useCompactLayout(
    state.uiMode,
    MediaQuery.sizeOf(context).width,
  );
  Widget content(BuildContext sheetContext) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 10, 2),
        child: Row(
          children: [
            const Expanded(child: InlineLabel('评论')),
            AccessibleIconButton(
              key: const ValueKey('desktop-panel-close'),
              tooltip: '关闭',
              onPressed: () => Navigator.of(sheetContext).pop(),
              icon: const Icon(Icons.close_rounded),
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
  if (compact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.ivoryLight,
      showDragHandle: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .76,
        child: content(sheetContext),
      ),
    );
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: context.colors.slateDark.withValues(alpha: .2),
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 620,
        height: MediaQuery.sizeOf(context).height * .76,
        child: content(dialogContext),
      ),
    ),
  );
}

/// Shared queue entry from the player header and desktop transport.
Future<void> showPlaybackQueue(BuildContext context, AppState state) async {
  if (!useCompactLayout(state.uiMode, MediaQuery.sizeOf(context).width)) {
    await showDialog<void>(
      context: context,
      barrierColor: context.colors.slateDark.withValues(alpha: .2),
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 580,
          height: MediaQuery.sizeOf(context).height * .76,
          child: PlaybackQueueView(
            state: state,
            onClose: () => Navigator.pop(context),
          ),
        ),
      ),
    );
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.ivoryLight,
    showDragHandle: true,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .76,
      child: PlaybackQueueView(
        state: state,
        onClose: () => Navigator.pop(context),
      ),
    ),
  );
}

/// Responsive cover/lyric spread with the same transport order on every size.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({
    super.key,
    required this.state,
    this.onClose,
    this.entranceSettled = true,
  });

  final AppState state;
  final VoidCallback? onClose;
  final bool entranceSettled;

  @override
  State<NowPlayingPage> createState() => _NowPlayingPageState();
}

class _NowPlayingPageState extends State<NowPlayingPage> {
  bool _lyricsMode = false;
  bool _controlsVisible = true;
  // Defaults to the non-destructive branch: a semantics-driven tap never
  // passes through onPointerDown, so it must not fold the lyrics away.
  bool _controlsHiddenAtTouchDown = true;
  bool _saving = false;
  bool _selectionOpen = false;
  bool _commentsOpen = false;
  bool _queueOpen = false;
  bool? _desktopLayout;
  DesktopNowPlayingPane _desktopPane = DesktopNowPlayingPane.lyrics;
  late SongCommentsController _commentsController;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _commentsController = SongCommentsController(widget.state.gateway);
    widget.state.addListener(_preferencesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.ensureCurrentLyrics());
    });
  }

  bool get _canAutoHide =>
      !_selectionOpen &&
      !_commentsOpen &&
      !_queueOpen &&
      (_desktopLayout == true
          ? _desktopPane == DesktopNowPlayingPane.lyrics
          : _lyricsMode) &&
      !widget.state.lyricsLoading &&
      widget.state.lyrics.isNotEmpty;

  void _preferencesChanged() {
    if (!_canAutoHide && !_controlsVisible) _wakeControls();
    _armHide();
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (!_canAutoHide) return;
    _hideTimer = Timer(
      Duration(
        milliseconds: (widget.state.lyricControlsSeconds * 1000).round(),
      ),
      _hideControls,
    );
  }

  void _selectionChanged(bool active) {
    _selectionOpen = active;
    if (active) {
      _hideTimer?.cancel();
    } else {
      _armHide();
    }
  }

  void _hideControls() {
    if (!mounted) return;
    if (!_canAutoHide) {
      _wakeControls();
      return;
    }
    // Retire floating tooltip nodes before their anchors become invisible.
    // Wait for real animation completion, including on a delayed frame.
    if (Tooltip.dismissAllToolTips()) {
      _hideTimer = Timer(const Duration(milliseconds: 16), _hideControls);
      return;
    }
    setState(() => _controlsVisible = false);
  }

  void _wakeControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible && mounted) setState(() => _controlsVisible = true);
  }

  void _controlsActivity() {
    _wakeControls();
    _armHide();
  }

  // Record the starting mode without waking the controls for lyric or drag
  // gestures. Only a completed background tap changes the presentation.
  void _onTouchDown() {
    _controlsHiddenAtTouchDown = !_controlsVisible;
  }

  /// Return one step only after a completed tap outside the lyric text.
  void _stepBackFromLyrics() {
    if (!_lyricsMode || _selectionOpen) return;
    if (_controlsHiddenAtTouchDown) {
      _wakeControls();
      _armHide();
    } else {
      _toggleLyrics();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.state.removeListener(_preferencesChanged);
    _commentsController.dispose();
    super.dispose();
  }

  void _toggleLyrics() {
    setState(() {
      _lyricsMode = !_lyricsMode;
      if (!_lyricsMode) _selectionOpen = false;
      _controlsVisible = true;
    });
    _armHide();
  }

  Future<void> _queue() async {
    _queueOpen = true;
    _hideTimer?.cancel();
    await showPlaybackQueue(context, widget.state);
    if (!mounted) return;
    _queueOpen = false;
    _wakeControls();
    _armHide();
  }

  void _closePage() {
    final VoidCallback? onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _toggleFullscreen() async {
    try {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
      } else {
        await windowManager.setFullScreen(true);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: TrText('无法切换全屏状态。')));
    }
  }

  Future<void> _openComments() async {
    final track = widget.state.current;
    if (track == null || _commentsOpen) return;
    _commentsOpen = true;
    _hideTimer?.cancel();
    await showSongComments(
      context,
      state: widget.state,
      track: track,
      controller: _commentsController,
    );
    if (!mounted) return;
    _commentsOpen = false;
    _wakeControls();
    _armHide();
  }

  void _selectDesktopPane(DesktopNowPlayingPane pane) {
    if (_desktopPane == pane) {
      _controlsActivity();
      return;
    }
    _hideTimer?.cancel();
    setState(() {
      _desktopPane = pane;
      _selectionOpen = false;
      _controlsVisible = true;
    });
    _armHide();
  }

  @override
  void didUpdateWidget(covariant NowPlayingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_preferencesChanged);
      widget.state.addListener(_preferencesChanged);
      _commentsController.dispose();
      _commentsController = SongCommentsController(widget.state.gateway);
    }
  }

  /// 移动端整屏歌词：标题固定，正文占满剩余高度。
  Widget _mobileLyrics() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const InlineLabel('歌词'),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: LyricViewport(
            state: widget.state,
            onSelectionChanged: _selectionChanged,
          ),
        ),
      ],
    ),
  );

  Future<void> _saveArtwork(Track track) async {
    if (_saving) return;
    _hideTimer?.cancel();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const TrText('保存封面图片？'),
        content: TrText('将「${track.title}」的封面保存在设备中。'),
        actions: [
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: context.colors.slateDark,
            ),
            onPressed: () => Navigator.pop(context, false),
            child: const TrText('取消'),
          ),
          FilledButton(
            onPressed: track.coverUrl == null
                ? null
                : () => Navigator.pop(context, true),
            child: const TrText('保存'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      _armHide();
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await saveCover(track.coverUrl!, track.title);
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('封面已保存')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('保存失败，请检查相册权限或稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
      _armHide();
    }
  }

  Widget _cover(Track track) => Semantics(
    label: context.tr('歌曲封面，长按保存'),
    child: GestureDetector(
      onTap: () {
        if (useCompactLayout(
          widget.state.uiMode,
          MediaQuery.sizeOf(context).width,
        )) {
          unawaited(widget.state.feedback());
          _toggleLyrics();
        }
      },
      onLongPress: () => unawaited(_saveArtwork(track)),
      child: AspectRatio(
        aspectRatio: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 24,
                spreadRadius: 1,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: KeyedSubtree(
              key: const ValueKey('legacy-now-playing-cover'),
              child: AnimatedTrackCover(
                track: track,
                direction: widget.state.trackChangeDirection,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _header(bool compact) => IgnorePointer(
    ignoring: compact && !_controlsVisible,
    child: AnimatedOpacity(
      opacity: compact && !_controlsVisible ? 0 : 1,
      duration: const Duration(milliseconds: 200),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: Row(
          children: [
            AccessibleIconButton(
              tooltip: '返回',
              onPressed: _closePage,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
            ),
            const Spacer(),
            if (_saving)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (compact)
              AccessibleIconButton(
                tooltip: '歌词',
                onPressed: _toggleLyrics,
                isSelected: _lyricsMode,
                icon: const Icon(Icons.lyrics_outlined),
              ),
            AccessibleIconButton(
              tooltip: '查看评论',
              onPressed: () => unawaited(_openComments()),
              icon: const Icon(Icons.chat_bubble_outline_rounded),
            ),
            AccessibleIconButton(
              tooltip: '播放队列',
              onPressed: _queue,
              icon: const Icon(Icons.queue_music_rounded),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Theme(
    data: buildAppTheme(
      brightness: Brightness.dark,
      accent: Theme.of(context).colorScheme.primary,
    ),
    child: Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          final Track? track = widget.state.current;
          return Stack(
            fit: StackFit.expand,
            children: [
              AlbumBlurFlow(
                track: track,
                mode: widget.state.legacyBackground,
                pageColor: Colors.black,
                animationsEnabled: widget.entranceSettled,
              ),
              if (track == null)
                _EmptyNowPlaying(onBack: _closePage)
              else
                LayoutBuilder(
                  builder: (context, box) {
                    final bool compact = useCompactLayout(
                      widget.state.uiMode,
                      box.maxWidth,
                    );
                    if (_desktopLayout != !compact) {
                      _desktopLayout = !compact;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          _wakeControls();
                          _armHide();
                        }
                      });
                    }
                    if (!compact) {
                      return SafeArea(
                        child: DesktopNowPlaying(
                          key: const ValueKey('desktop-now-playing'),
                          state: widget.state,
                          track: track,
                          artwork: _cover(track),
                          lyrics: LyricViewport(
                            state: widget.state,
                            onSelectionChanged: _selectionChanged,
                          ),
                          comments: SongCommentsView(
                            state: widget.state,
                            track: track,
                            controller: _commentsController,
                          ),
                          queue: PlaybackQueueView(
                            state: widget.state,
                            showHeader: false,
                          ),
                          pane: _desktopPane,
                          onPaneChanged: _selectDesktopPane,
                          onBack: _closePage,
                          onSaveArtwork: () => unawaited(_saveArtwork(track)),
                          onFullscreen: () => unawaited(_toggleFullscreen()),
                          controlsVisible: _controlsVisible,
                          onActivity: _controlsActivity,
                        ),
                      );
                    }
                    return Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: (_) => _onTouchDown(),
                      onPointerUp: (_) => _armHide(),
                      onPointerCancel: (_) => _armHide(),
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTap: compact && _lyricsMode
                            ? _stepBackFromLyrics
                            : null,
                        child: SafeArea(
                          child: Column(
                            children: [
                              _header(compact),
                              Expanded(child: _mobile(track)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    ),
  );

  Widget _readingPane(Track track) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 280),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(animation),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) => Stack(
      fit: StackFit.expand,
      children: [
        for (final old in previous)
          ExcludeSemantics(child: IgnorePointer(child: old)),
        ?current,
      ],
    ),
    child: _lyricsMode
        ? KeyedSubtree(
            key: const ValueKey('mobile-lyrics'),
            child: _mobileLyrics(),
          )
        : LayoutBuilder(
            key: const ValueKey('mobile-cover'),
            builder: (context, box) => Center(
              child: SizedBox.square(
                dimension: (box.maxHeight - 16).clamp(
                  0,
                  box.maxWidth.clamp(0, 380),
                ),
                child: _cover(track),
              ),
            ),
          ),
  );

  Widget _mobile(Track track) {
    final size = MediaQuery.sizeOf(context);
    final visible = !_lyricsMode || _controlsVisible;
    if (size.height < 500 && size.width > size.height) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: LayoutBuilder(
          builder: (context, box) => Row(
            children: [
              Expanded(child: _readingPane(track)),
              IgnorePointer(
                ignoring: !visible,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 360),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => SizeTransition(
                    axis: Axis.horizontal,
                    sizeFactor: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: !visible
                      ? const SizedBox.shrink(key: ValueKey('hidden'))
                      : SizedBox(
                          key: const ValueKey('controls'),
                          width: (box.maxWidth * 0.6).clamp(280, 400),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 20),
                            child: Column(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    child: _TrackDetails(
                                      track: track,
                                      state: widget.state,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                _PlaybackTransport(
                                  track: track,
                                  state: widget.state,
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
      child: Column(
        children: [
          Expanded(child: _readingPane(track)),
          IgnorePointer(
            ignoring: !visible,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 360),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => SizeTransition(
                sizeFactor: animation,
                child: FadeTransition(opacity: animation, child: child),
              ),
              child: visible
                  ? Padding(
                      key: const ValueKey('controls'),
                      padding: const EdgeInsets.only(top: 16),
                      child: _TrackInfo(track: track, state: widget.state),
                    )
                  : const SizedBox.shrink(key: ValueKey('hidden')),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({required this.track, required this.state});
  final Track track;
  final AppState state;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _TrackDetails(track: track, state: state),
      const SizedBox(height: 16),
      _PlaybackTransport(track: track, state: state),
    ],
  );
}

class _TrackDetails extends StatelessWidget {
  const _TrackDetails({required this.track, required this.state});
  final Track track;
  final AppState state;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.subheading.copyWith(
                fontSize: MediaQuery.sizeOf(context).width < 720 ? 24 : 28,
              ),
            ),
          ),
          AccessibleIconButton(
            tooltip: state.signedIn ? '收藏歌曲' : '登录后收藏',
            onPressed: state.signedIn
                ? () => unawaited(state.toggleLikeCurrent())
                : null,
            icon: Icon(
              state.currentLiked
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              color: state.currentLiked
                  ? context.colors.clayDeep
                  : context.colors.cloudDark,
            ),
          ),
        ],
      ),
      if (track.translatedTitle?.isNotEmpty ?? false) ...[
        const SizedBox(height: 4),
        Text(
          track.translatedTitle!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.type.bodySm.copyWith(
            fontSize: 15,
            color: context.colors.cloudDark,
          ),
        ),
      ],
      const SizedBox(height: 4),
      DefaultTextStyle(
        style: context.type.body.copyWith(
          fontSize: 17,
          color: context.colors.cloudDark,
        ),
        child: Row(
          children: [
            Flexible(
              child: ArtistNameLink(
                state: state,
                artists: track.artists,
                fallback: track.artist,
              ),
            ),
            if (track.album.isNotEmpty) ...[
              const Text(' · '),
              Flexible(
                child: AlbumNameLink(state: state, track: track),
              ),
            ],
          ],
        ),
      ),
      if (state.likeError != null) ...[
        const SizedBox(height: AppSpacing.sm),
        TrText(
          state.likeError!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.type.caption.copyWith(color: context.colors.clayDeep),
        ),
      ],
    ],
  );
}

class _PlaybackTransport extends StatelessWidget {
  const _PlaybackTransport({required this.track, required this.state});
  final Track track;
  final AppState state;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: DecoratedBox(
      decoration: const BoxDecoration(color: Colors.transparent),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          key: const ValueKey('now-playing-transport'),
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedNotice(
              message: state.playbackError,
              onDismiss: state.clearPlaybackError,
            ),
            PlayerSeekBar(state: state),
            const SizedBox(height: AppSpacing.sm),
            // Time labels ride the tick lane so position updates never rebuild
            // the whole page.
            AnimatedBuilder(
              animation: state.all,
              builder: (BuildContext context, _) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(fmt(state.position), style: context.type.monoSm),
                  Text(fmt(track.duration), style: context.type.monoSm),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // Fill the rail width so the last control has no trailing empty slab.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ControlIcon(
                  icon: state.shuffle
                      ? Icons.shuffle_on_rounded
                      : Icons.shuffle_rounded,
                  active: state.shuffle,
                  tooltip: '随机播放',
                  onTap: state.toggleShuffle,
                ),
                _ControlIcon(
                  icon: Icons.skip_previous_rounded,
                  size: 34,
                  tooltip: '上一首',
                  onTap: state.previous,
                ),
                _BigPlayPause(playing: state.playing, onTap: state.togglePlay),
                _ControlIcon(
                  icon: Icons.skip_next_rounded,
                  size: 34,
                  tooltip: '下一首',
                  onTap: state.next,
                ),
                _ControlIcon(
                  icon: state.repeat == LoopMode.one
                      ? Icons.repeat_one_on_rounded
                      : Icons.repeat_rounded,
                  active: state.repeat != LoopMode.off,
                  tooltip: '循环播放',
                  onTap: state.cycleRepeat,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ControlIcon extends StatefulWidget {
  const _ControlIcon({
    required this.icon,
    required this.onTap,
    this.active = false,
    this.tooltip,
    this.size = 26,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final String? tooltip;
  final double size;

  @override
  State<_ControlIcon> createState() => _ControlIconState();
}

class _ControlIconState extends State<_ControlIcon> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final Color color = !enabled
        ? context.colors.cloudMedium
        : widget.active || _hovering
        ? context.colors.slateDark
        : context.colors.cloudDark;
    final Widget btn = MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Icon(widget.icon, size: widget.size, color: color),
          ),
        ),
      ),
    );
    return widget.tooltip == null
        ? btn
        : AccessibleTooltip(message: widget.tooltip!, child: btn);
  }
}

class _BigPlayPause extends StatelessWidget {
  const _BigPlayPause({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => AccessibleIconButton(
    key: const ValueKey('now-playing-play'),
    tooltip: playing ? '暂停' : '播放',
    onPressed: onTap,
    iconSize: 38,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 68, height: 68),
    color: context.colors.onPlayer,
    style: IconButton.styleFrom(
      backgroundColor: Colors.transparent,
      foregroundColor: context.colors.onPlayer,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      minimumSize: const Size(68, 68),
      shape: const CircleBorder(),
    ),
    icon: AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(playing),
        size: 38,
      ),
    ),
  );
}

class _EmptyNowPlaying extends StatelessWidget {
  const _EmptyNowPlaying({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrText('没有正在播放的曲目', style: context.type.subheading),
          const SizedBox(height: AppSpacing.sm),
          TrText(
            '回到曲库，翻开一页吧。',
            style: context.type.bodyMuted.copyWith(fontSize: 16),
          ),
          const SizedBox(height: AppSpacing.lg),
          IvoryButton(label: '返回', onPressed: onBack),
        ],
      ),
    );
  }
}
