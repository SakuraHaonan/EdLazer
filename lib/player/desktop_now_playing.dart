import 'dart:async';
import '../widgets/catalog_links.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import '../widgets/accessible_controls.dart';
import '../widgets/animated_notice.dart';
import '../widgets/player_seek_bar.dart';
import '../widgets/interaction_feedback.dart';
import '../widgets/volume_control.dart';

enum DesktopNowPlayingPane { lyrics, comments, queue }

/// Desktop listening workspace with an unscrolled, collapsible transport dock.
class DesktopNowPlaying extends StatelessWidget {
  const DesktopNowPlaying({
    super.key,
    required this.state,
    required this.track,
    required this.artwork,
    required this.lyrics,
    required this.comments,
    required this.queue,
    required this.pane,
    required this.onPaneChanged,
    required this.onBack,
    required this.onSaveArtwork,
    required this.onFullscreen,
    required this.controlsVisible,
    required this.onActivity,
  });
  final AppState state;
  final Track track;
  final Widget artwork, lyrics, comments, queue;
  final DesktopNowPlayingPane pane;
  final ValueChanged<DesktopNowPlayingPane> onPaneChanged;
  final VoidCallback onBack, onSaveArtwork, onFullscreen;
  final bool controlsVisible;
  final VoidCallback onActivity;

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) onActivity();
      return KeyEventResult.ignored;
    },
    child: MouseRegion(
      onEnter: (_) => onActivity(),
      onHover: (_) => onActivity(),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => onActivity(),
        onPointerUp: (_) => onActivity(),
        onPointerCancel: (_) => onActivity(),
        onPointerSignal: (_) => onActivity(),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 20, 8),
              child: Row(
                children: [
                  AccessibleIconButton(
                    key: const ValueKey('desktop-close'),
                    tooltip: '返回',
                    onPressed: onBack,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(child: InlineLabel('正在播放')),
                  _PaneTab(
                    key: const ValueKey('desktop-lyrics'),
                    label: '歌词',
                    icon: Icons.lyrics_outlined,
                    active: pane == DesktopNowPlayingPane.lyrics,
                    onPressed: () =>
                        onPaneChanged(DesktopNowPlayingPane.lyrics),
                  ),
                  const SizedBox(width: 8),
                  AccessibleTooltip(
                    message: '查看评论',
                    child: _PaneTab(
                      key: const ValueKey('desktop-comments'),
                      label: '评论',
                      icon: Icons.chat_bubble_outline_rounded,
                      active: pane == DesktopNowPlayingPane.comments,
                      onPressed: () =>
                          onPaneChanged(DesktopNowPlayingPane.comments),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AccessibleTooltip(
                    message: '播放队列 (Q)',
                    child: _PaneTab(
                      key: const ValueKey('desktop-queue'),
                      label: '播放队列',
                      icon: Icons.queue_music_rounded,
                      active: pane == DesktopNowPlayingPane.queue,
                      onPressed: () =>
                          onPaneChanged(DesktopNowPlayingPane.queue),
                    ),
                  ),
                  const SizedBox(width: 8),
                  AccessibleIconButton(
                    key: const ValueKey('desktop-fullscreen'),
                    tooltip: '全屏 (F)',
                    onPressed: onFullscreen,
                    icon: const Icon(Icons.fullscreen_rounded),
                  ),
                  AccessibleIconButton(
                    key: const ValueKey('desktop-more'),
                    tooltip: '保存封面',
                    onPressed: onSaveArtwork,
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Padding(
                  padding: const EdgeInsets.fromLTRB(32, 24, 24, 24),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: (box.maxWidth * .34).clamp(240, 440),
                        child: _Presentation(
                          track: track,
                          state: state,
                          artwork: artwork,
                        ),
                      ),
                      const SizedBox(width: 32),
                      const SizedBox(width: 16),
                      Expanded(
                        child: RepaintBoundary(
                          child: AnimatedSwitcher(
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween(
                                      begin: const Offset(.025, 0),
                                      end: Offset.zero,
                                    ).animate(animation),
                                    child: child,
                                  ),
                                ),
                            layoutBuilder: (current, previous) => Stack(
                              fit: StackFit.expand,
                              children: [
                                for (final old in previous)
                                  ExcludeSemantics(
                                    child: IgnorePointer(child: old),
                                  ),
                                ?current,
                              ],
                            ),
                            child: KeyedSubtree(
                              key: ValueKey(pane),
                              child: switch (pane) {
                                DesktopNowPlayingPane.lyrics => lyrics,
                                DesktopNowPlayingPane.comments => comments,
                                DesktopNowPlayingPane.queue => queue,
                              },
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _DesktopDock(state: state, visible: controlsVisible),
          ],
        ),
      ),
    ),
  );
}

class _PaneTab extends StatelessWidget {
  const _PaneTab({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Semantics(
    selected: active,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            width: 2,
            color: active ? context.colors.slateDark : Colors.transparent,
          ),
        ),
      ),
      child: TextButton.icon(
        onPressed: feedbackAction(context, onPressed),
        style: TextButton.styleFrom(
          shape: const RoundedRectangleBorder(),
          minimumSize: const Size(0, 44),
          foregroundColor: active
              ? context.colors.slateDark
              : context.colors.cloudDark,
        ),
        icon: Icon(icon, size: 19),
        label: TrText(label),
      ),
    ),
  );
}

class _Presentation extends StatelessWidget {
  const _Presentation({
    required this.track,
    required this.state,
    required this.artwork,
  });
  final Track track;
  final AppState state;
  final Widget artwork;

  Widget _metadata(BuildContext context, {bool compact = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.type.heading.copyWith(
                fontSize: compact ? 22 : 30,
                height: 1.2,
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
      if (track.translatedTitle?.isNotEmpty ?? false)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            track.translatedTitle!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.type.bodySmMuted.copyWith(
              fontSize: compact ? 12 : 15,
            ),
          ),
        ),
      SizedBox(height: compact ? 8 : 12),
      ArtistNameLink(
        state: state,
        artists: track.artists,
        fallback: track.artist,
        maxLines: 2,
        style: context.type.body.copyWith(fontSize: compact ? 14 : 18),
      ),
      SizedBox(height: compact ? 4 : 6),
      AlbumNameLink(
        state: state,
        track: track,
        style: context.type.bodySmMuted.copyWith(fontSize: compact ? 12 : 15),
      ),
      AnimatedNotice(message: state.likeError),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxHeight < 320 * MediaQuery.textScalerOf(context).scale(1)) {
        return SingleChildScrollView(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: 72,
                child: RepaintBoundary(child: artwork),
              ),
              const SizedBox(width: 16),
              Expanded(child: _metadata(context, compact: true)),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Center(
              child: AspectRatio(
                aspectRatio: 1,
                child: RepaintBoundary(child: artwork),
              ),
            ),
          ),
          const SizedBox(height: 24),
          _metadata(context),
        ],
      );
    },
  );
}

class _DesktopDock extends StatelessWidget {
  const _DesktopDock({required this.state, required this.visible});
  final AppState state;
  final bool visible;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: state,
    builder: (context, _) => AnimatedSwitcher(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 360),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) => SizeTransition(
        axis: Axis.vertical,
        sizeFactor: animation,
        alignment: Alignment.bottomCenter,
        child: FadeTransition(opacity: animation, child: child),
      ),
      child: !visible
          ? const SizedBox.shrink(key: ValueKey('hidden-desktop-dock'))
          : Padding(
              key: const ValueKey('visible-desktop-dock'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.transparent),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                    child: Column(
                      key: const ValueKey('now-playing-transport'),
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 200),
                          transitionBuilder: (child, animation) =>
                              SizeTransition(
                                sizeFactor: animation,
                                child: FadeTransition(
                                  opacity: animation,
                                  child: child,
                                ),
                              ),
                          child: state.playbackError == null
                              ? const SizedBox.shrink(
                                  key: ValueKey('no-playback-error'),
                                )
                              : Row(
                                  key: ValueKey(state.playbackError),
                                  children: [
                                    Icon(
                                      Icons.info_outline_rounded,
                                      size: 16,
                                      color: context.colors.clayDeep,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TrText(
                                        state.playbackError!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.type.caption.copyWith(
                                          color: context.colors.clayDeep,
                                        ),
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '关闭提示',
                                      onPressed: state.clearPlaybackError,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      style: IconButton.styleFrom(
                                        minimumSize: const Size(32, 32),
                                        padding: const EdgeInsets.all(4),
                                        tapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                      ),
                                      icon: const Icon(
                                        Icons.close_rounded,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                        Row(
                          children: [
                            _Clock(state: state),
                            const SizedBox(width: 12),
                            Expanded(
                              child: PlayerSeekBar(
                                key: const ValueKey('desktop-seek-bar'),
                                state: state,
                                trackHeight: 3,
                                thumbRadius: 5,
                              ),
                            ),
                            const SizedBox(width: 12),
                            _Clock(state: state, end: true),
                          ],
                        ),
                        Row(
                          children: [
                            const Spacer(flex: 2),
                            Expanded(
                              flex: 3,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  children: [
                                    AccessibleIconButton(
                                      tooltip: '随机播放',
                                      onPressed: state.toggleShuffle,
                                      color: state.shuffle
                                          ? context.colors.clayDeep
                                          : context.colors.cloudDark,
                                      icon: Icon(
                                        state.shuffle
                                            ? Icons.shuffle_on_rounded
                                            : Icons.shuffle_rounded,
                                        size: 23,
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '上一首',
                                      onPressed: state.previous,
                                      icon: const Icon(
                                        Icons.skip_previous_rounded,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AccessibleIconButton(
                                      key: const ValueKey('desktop-play-pause'),
                                      tooltip: state.playing ? '暂停' : '播放',
                                      color: context.colors.onPlayer,
                                      onPressed: state.togglePlay,
                                      icon: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        child: Icon(
                                          state.playing
                                              ? Icons.pause_rounded
                                              : Icons.play_arrow_rounded,
                                          key: ValueKey(state.playing),
                                          size: 28,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    AccessibleIconButton(
                                      tooltip: '下一首',
                                      onPressed: state.next,
                                      icon: const Icon(
                                        Icons.skip_next_rounded,
                                        size: 28,
                                      ),
                                    ),
                                    AccessibleIconButton(
                                      tooltip: '循环播放',
                                      onPressed: state.cycleRepeat,
                                      color: state.repeat != LoopMode.off
                                          ? context.colors.clayDeep
                                          : context.colors.cloudDark,
                                      icon: Icon(
                                        state.repeat == LoopMode.one
                                            ? Icons.repeat_one_rounded
                                            : Icons.repeat_rounded,
                                        size: 23,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: VolumeControl(state: state),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    ),
  );
}

class _Clock extends StatelessWidget {
  const _Clock({required this.state, this.end = false});
  final AppState state;
  final bool end;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 54 * MediaQuery.textScalerOf(context).scale(1),
    child: AnimatedBuilder(
      animation: state.all,
      builder: (context, _) => Text(
        fmt(end ? state.current?.duration ?? Duration.zero : state.position),
        textAlign: end ? TextAlign.right : TextAlign.left,
        style: context.type.monoSm,
      ),
    ),
  );
}
