import 'package:lazer_nextgen/theme/app_palette.dart';
import '../l10n/app_localizations.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/haptic_seek_slider.dart';
import '../widgets/animated_track_cover.dart';
import '../widgets/volume_control.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoFullscreenDialogTransition;

import '../widgets/lyric_viewport.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';
import '../widgets/plate_art.dart';
import '../widgets/animated_notice.dart';
import '../utils/cover_save.dart';

/// A full-height sheet on every platform; Android keeps predictive back.
class NowPlayingRoute extends MaterialPageRoute<void> {
  NowPlayingRoute({required AppState state})
    : super(builder: (_) => NowPlayingPage(state: state));

  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 420);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 340);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      return CupertinoFullscreenDialogTransition(
        primaryRouteAnimation: animation,
        secondaryRouteAnimation: secondaryAnimation,
        linearTransition: popGestureInProgress,
        child: child,
      );
    }
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final progress =
            (animation.status == AnimationStatus.reverse
                    ? Curves.easeInCubic
                    : Curves.easeOutCubic)
                .transform(animation.value);
        final page = SlideTransition(
          key: const ValueKey('now-playing-page-transition'),
          position: AlwaysStoppedAnimation(
            popGestureInProgress ? Offset.zero : Offset(0, 1 - progress),
          ),
          child: child,
        );
        if (platform == TargetPlatform.android) {
          return const PredictiveBackFullscreenPageTransitionsBuilder()
              .buildTransitions(
                this,
                context,
                popGestureInProgress
                    ? animation
                    : const AlwaysStoppedAnimation(1),
                secondaryAnimation,
                page,
              );
        }
        return page;
      },
    );
  }
}

/// Shared queue entry from the player header and desktop transport.
Future<void> showPlaybackQueue(BuildContext context, AppState state) async {
  if (MediaQuery.sizeOf(context).width >= 720) {
    await showDialog<void>(
      context: context,
      barrierColor: context.colors.slateDark.withValues(alpha: .2),
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 580,
          height: MediaQuery.sizeOf(context).height * .76,
          child: AnimatedBuilder(
            animation: state,
            builder: (_, _) => _QueueAppendix(state: state),
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
    builder: (_) => AnimatedBuilder(
      animation: state,
      builder: (context, _) => _QueueAppendix(state: state),
    ),
  );
}

/// Responsive cover/lyric spread with the same transport order on every size.
class NowPlayingPage extends StatefulWidget {
  const NowPlayingPage({super.key, required this.state});
  final AppState state;

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
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_preferencesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.state.ensureCurrentLyrics());
    });
  }

  void _preferencesChanged() {
    if (_lyricsMode) {
      if (widget.state.lyrics.isEmpty) _wakeControls();
      _armHide();
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (_selectionOpen ||
        !_lyricsMode ||
        widget.state.lyricsLoading ||
        widget.state.lyrics.isEmpty) {
      return;
    }
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
    if (!_controlsVisible) setState(() => _controlsVisible = true);
  }

  // The page Listener wakes the controls before the row reports its tap, so
  // the tap has to be judged against the state this touch interrupted.
  void _onTouchDown() {
    _controlsHiddenAtTouchDown = !_controlsVisible;
    _wakeControls();
  }

  /// Mobile two-step lyric tap: reveal the transport, then fold the lyrics in.
  bool _onLyricLineTap(int index, bool isCurrentLine) {
    if (isCurrentLine) return false;
    if (_controlsHiddenAtTouchDown) {
      _wakeControls();
      return true;
    }
    _toggleLyrics();
    return true;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.state.removeListener(_preferencesChanged);
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

  void _queue() => showPlaybackQueue(context, widget.state);

  Widget _lyricsPane() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // 固定标题，不参与滚动
      const InlineLabel('歌词'),
      const SizedBox(height: AppSpacing.md),

      // 歌词正文自带一个有界视口
      Expanded(
        child: LyricViewport(
          state: widget.state,
          onSelectionChanged: _selectionChanged,
        ),
      ),
    ],
  );

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
            onLineTap: _onLyricLineTap,
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
        if (MediaQuery.sizeOf(context).width < 720) {
          unawaited(widget.state.feedback());
          _toggleLyrics();
        }
      },
      onLongPress: () => unawaited(_saveArtwork(track)),
      child: AspectRatio(
        aspectRatio: 1,
        child: AnimatedTrackCover(
          track: track,
          direction: widget.state.trackChangeDirection,
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
              onPressed: () => Navigator.maybePop(context),
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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.colors.ivoryMedium,
    body: AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final track = widget.state.current;
        if (track == null) {
          return _EmptyNowPlaying(onBack: () => Navigator.maybePop(context));
        }
        return LayoutBuilder(
          builder: (context, box) {
            final compact = box.maxWidth < 720;
            return Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _onTouchDown(),
              onPointerUp: (_) => _armHide(),
              onPointerCancel: (_) => _armHide(),
              child: SafeArea(
                child: Column(
                  children: [
                    _header(compact),
                    Expanded(
                      child: compact ? _mobile(track) : _desktop(track, box),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );

  Widget _desktop(Track track, BoxConstraints box) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 20, 32, 28),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: (box.maxWidth * 0.28).clamp(260, 360),
          child: LayoutBuilder(
            builder: (context, rail) => _desktopRail(track, rail),
          ),
        ),
        SizedBox(width: box.maxWidth > 1100 ? 80 : 40),
        Expanded(
          child: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: _lyricsPane(),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _desktopRail(Track track, BoxConstraints rail) {
    final controls = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PlaybackTransport(track: track, state: widget.state),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: VolumeControl(state: widget.state),
        ),
      ],
    );
    if (rail.maxHeight < 500 * MediaQuery.textScalerOf(context).scale(1)) {
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox.square(dimension: 64, child: _cover(track)),
                const SizedBox(width: 12),
                Expanded(
                  child: _TrackDetails(track: track, state: widget.state),
                ),
              ],
            ),
            const SizedBox(height: 16),
            controls,
          ],
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: CustomMultiChildLayout(
            delegate: _ArtworkDetailsLayout(),
            children: [
              LayoutId(id: 'art', child: _cover(track)),
              LayoutId(
                id: 'details',
                child: _TrackDetails(track: track, state: widget.state),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        controls,
      ],
    );
  }

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

class _ArtworkDetailsLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final details = layoutChild(
      'details',
      BoxConstraints(
        minWidth: size.width,
        maxWidth: size.width,
        maxHeight: size.height,
      ),
    );
    final side = (size.height - details.height - 16).clamp(0.0, size.width);
    layoutChild('art', BoxConstraints.tight(Size(size.width, side)));
    positionChild('art', Offset.zero);
    positionChild('details', Offset(0, side + 16));
  }

  @override
  bool shouldRelayout(covariant _ArtworkDetailsLayout oldDelegate) => false;
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
      Text(
        '${track.artist} · ${track.album}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.type.body.copyWith(
          fontSize: 17,
          color: context.colors.cloudDark,
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
  Widget build(BuildContext context) => Column(
    key: const ValueKey('now-playing-transport'),
    mainAxisSize: MainAxisSize.min,
    children: [
      AnimatedNotice(
        message: state.playbackError,
        onDismiss: state.clearPlaybackError,
      ),
      _NowPlayingSeek(state: state),
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
  );
}

class _NowPlayingSeek extends StatelessWidget {
  const _NowPlayingSeek({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    // Leaf: the only part of Now Playing that consumes 100 ms ticks.
    return AnimatedBuilder(
      animation: state.all,
      builder: (BuildContext context, _) => SliderTheme(
        data: SliderThemeData(
          trackHeight: 4,
          activeTrackColor: context.colors.slateDark,
          inactiveTrackColor: context.colors.stone,
          thumbColor: context.colors.clay,
          overlayColor: context.colors.clay.withValues(alpha: 0.16),
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 15),
        ),
        child: HapticSeekSlider(state: state),
      ),
    );
  }
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

class _BigPlayPause extends StatefulWidget {
  const _BigPlayPause({required this.playing, required this.onTap});

  final bool playing;
  final VoidCallback onTap;

  @override
  State<_BigPlayPause> createState() => _BigPlayPauseState();
}

class _BigPlayPauseState extends State<_BigPlayPause> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: feedbackAction(context, widget.onTap),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          width: 68,
          height: 68,
          // Ink disc with the paper knocked out of it; hover trades the two.
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovering
                ? context.colors.manilla
                : context.colors.slateDark,
          ),
          child: Icon(
            widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: 38,
            color: _hovering ? context.colors.slateDark : context.colors.onInk,
          ),
        ),
      ),
    );
  }
}

class _QueueAppendix extends StatefulWidget {
  const _QueueAppendix({required this.state});
  final AppState state;
  @override
  State<_QueueAppendix> createState() => _QueueAppendixState();
}

class _QueueAppendixState extends State<_QueueAppendix> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset:
        (widget.state.queue.indexWhere(
                  (track) => track.id == widget.state.current?.id,
                ) -
                2)
            .clamp(0, widget.state.queue.length) *
        76.0,
  );
  AppState get state => widget.state;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.76,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TrText(
                    '播放队列 · ${state.queue.length} 首',
                    style: context.type.subheading,
                  ),
                ),
                AccessibleIconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: 76,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: state.queue.length,
              itemBuilder: (context, i) => _QueueRow(
                track: state.queue[i],
                index: i,
                state: state,
                isCurrent: state.current?.id == state.queue[i].id,
                playing:
                    state.playing && state.current?.id == state.queue[i].id,
                onTap: () => state.playTrackAt(i),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.track,
    required this.index,
    required this.state,
    required this.isCurrent,
    required this.playing,
    required this.onTap,
  });

  final Track track;
  final int index;
  final AppState state;
  final bool isCurrent;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: feedbackAction(context, onTap),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: isCurrent
                ? context.colors.oatWarm.withValues(alpha: .6)
                : context.colors.oatWarm.withValues(alpha: 0),
            border: Border(
              left: BorderSide(
                color: isCurrent
                    ? context.colors.clay
                    : context.colors.clay.withValues(alpha: 0),
                width: 2,
              ),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  (index + 1).toString().padLeft(2, '0'),
                  style: context.type.monoSm.copyWith(
                    color: isCurrent
                        ? context.colors.slateDark
                        : context.colors.cloudMedium,
                  ),
                ),
              ),
              SizedBox.square(
                dimension: 48,
                child: PlateArt(
                  seed: track.coverSeed,
                  coverUrl: track.coverUrl,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.body.copyWith(
                        fontSize: 15,
                        height: 1.3,
                        fontWeight: isCurrent
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.type.captionMuted,
                    ),
                  ],
                ),
              ),
              if (playing)
                _PlayingBars(state: state)
              else
                Text(fmt(track.duration), style: context.type.monoSm),
            ],
          ),
        ),
      ),
    );
  }
}

/// Three tiny animated bars marking the active track — a spare line indicator
/// in the warm-neutral family, not a color accent.
///
/// Driven by the discrete 100 ms tick lane instead of a repeating
/// AnimationController: the old 900 ms `repeat(reverse: true)` kept the UI
/// isolate never-idle at 60 fps while playing, and — on Windows, where an
/// accessibility client forces per-frame AXTree syncs on the platform
/// thread — that starved the message pump and read as a UI freeze.
/// Implicit 220 ms steps, bounded and excluded from the semantics tree,
/// keep the living feel without the busy loop.
class _PlayingBars extends StatefulWidget {
  const _PlayingBars({required this.state});

  final AppState state;

  @override
  State<_PlayingBars> createState() => _PlayingBarsState();
}

class _PlayingBarsState extends State<_PlayingBars> {
  int _step = 0;

  @override
  void initState() {
    super.initState();
    widget.state.ticks.addListener(_advance);
  }

  @override
  void didUpdateWidget(covariant _PlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.ticks.removeListener(_advance);
      widget.state.ticks.addListener(_advance);
    }
  }

  void _advance() {
    if (mounted) setState(() => _step = (_step + 1) % 4);
  }

  @override
  void dispose() {
    widget.state.ticks.removeListener(_advance);
    super.dispose();
  }

  static final List<List<double>> _pattern = <List<double>>[
    <double>[5, 11, 8],
    <double>[9, 6, 12],
    <double>[12, 10, 5],
    <double>[7, 12, 9],
  ];

  @override
  Widget build(BuildContext context) {
    final List<double> h = _pattern[_step];
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (int i = 0; i < 3; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                width: 2.5,
                height: h[i],
                margin: const EdgeInsets.only(right: 2.5),
                color: context.colors.slateDark,
              ),
          ],
        ),
      ),
    );
  }
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
