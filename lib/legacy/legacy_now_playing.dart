import 'dart:async';

import 'package:flutter/material.dart';

import '../data/lyrics.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'legacy_widgets.dart';

/// The legacy now-playing page: cover and title on the left, the scrolling
/// lyric column on the right, transport underneath.
class LegacyNowPlayingPage extends StatefulWidget {
  const LegacyNowPlayingPage({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyNowPlayingPage> createState() => _LegacyNowPlayingPageState();
}

class _LegacyNowPlayingPageState extends State<LegacyNowPlayingPage> {
  static const double _lineExtent = 58;

  final ScrollController _lyricsScroll = ScrollController();
  int _activeLine = 0;

  AppState get state => widget.state;

  @override
  void dispose() {
    _lyricsScroll.dispose();
    super.dispose();
  }

  int _lineFor(List<LyricLine> lines, Duration position) {
    int index = 0;
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].time <= position) {
        index = i;
      } else {
        break;
      }
    }
    return index;
  }

  void _followLyrics(int index, int count) {
    if (index == _activeLine || !_lyricsScroll.hasClients) {
      _activeLine = index;
      return;
    }
    _activeLine = index;
    final double viewport = _lyricsScroll.position.viewportDimension;
    final double target = (index * _lineExtent - viewport / 2 + _lineExtent / 2)
        .clamp(0.0, _lyricsScroll.position.maxScrollExtent);
    unawaited(
      _lyricsScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, _) {
          final Track? track = state.current;
          if (track == null) {
            return SafeArea(
              child: Column(
                children: [
                  _header(context, '正在播放', showQueue: false),
                  const Expanded(child: LegacyNotice(message: '还没有播放中的曲目。')),
                ],
              ),
            );
          }
          final bool wide = MediaQuery.sizeOf(context).width >= 860;
          final Widget cover = Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              LegacyCover(url: track.coverUrl, size: wide ? 320 : 220, radius: 24),
              const SizedBox(height: 22),
              Text(
                track.title,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                track.artist,
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (track.album.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  track.album,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: state.currentLiked ? '取消喜欢' : '喜欢',
                    onPressed: () => unawaited(state.toggleLikeCurrent()),
                    icon: Icon(
                      state.currentLiked
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: state.currentLiked
                          ? scheme.tertiary
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  IconButton(
                    tooltip: '播放队列',
                    onPressed: () => _showQueue(context),
                    icon: const Icon(Icons.queue_music_rounded),
                  ),
                ],
              ),
            ],
          );
          final Widget lyrics = _lyrics(context);
          final Widget bottom = Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: LegacyProgressBar(state: state),
              ),
              LegacyTransportControls(state: state, large: true),
              const SizedBox(height: 10),
            ],
          );
          return SafeArea(
            child: Column(
              children: [
                _header(context, '正在播放'),
                Expanded(
                  child: wide
                      ? Row(
                          children: [
                            Expanded(flex: 5, child: cover),
                            Expanded(
                              flex: 6,
                              child: Padding(
                                padding: const EdgeInsets.only(right: 24),
                                child: lyrics,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 5, child: SingleChildScrollView(child: cover)),
                            Expanded(
                              flex: 4,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 24),
                                child: lyrics,
                              ),
                            ),
                          ],
                        ),
                ),
                bottom,
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _header(BuildContext context, String title, {bool showQueue = true}) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 26),
          ),
          const SizedBox(width: 4),
          Text(title, style: theme.textTheme.titleMedium),
          const Spacer(),
          if (showQueue)
            IconButton(
              tooltip: '播放队列',
              onPressed: () => _showQueue(context),
              icon: const Icon(Icons.queue_music_rounded, size: 22),
            ),
        ],
      ),
    );
  }

  Widget _lyrics(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (state.lyricsLoading && state.lyrics.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final List<LyricLine> lines = state.lyrics;
    if (lines.isEmpty) {
      return LegacyNotice(
        message: state.lyricsPureMusic ? '纯音乐，请欣赏' : '这首歌还没有同步歌词。',
      );
    }
    return AnimatedBuilder(
      animation: state.all,
      builder: (BuildContext context, _) {
        final int active = _lineFor(lines, state.precisePosition);
        if (active != _activeLine) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _followLyrics(active, lines.length);
          });
        }
        return ListView.builder(
          controller: _lyricsScroll,
          itemExtent: _lineExtent,
          padding: const EdgeInsets.symmetric(vertical: 40),
          itemCount: lines.length,
          itemBuilder: (BuildContext context, int index) {
            final bool current = index == active;
            return GestureDetector(
              onTap: () {
                final Duration total = AudioStateDuration.of(state);
                if (total.inMilliseconds > 0) {
                  state.seek(
                    lines[index].time.inMilliseconds /
                        total.inMilliseconds,
                  );
                }
              },
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 220),
                    style: (current
                            ? theme.textTheme.titleLarge
                            : theme.textTheme.bodyLarge)!
                        .copyWith(
                          color: current ? scheme.primary : scheme.onSurfaceVariant,
                          fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                        ),
                    child: Text(
                      lines[index].text.isEmpty ? '…' : lines[index].text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (lines[index].translation?.isNotEmpty ?? false)
                    Text(
                      lines[index].translation!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            );
          },
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
      builder: (BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: SafeArea(
          child: state.queue.isEmpty
              ? const LegacyNotice(message: '队列还是空的。')
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
      ),
    );
  }
}

/// The current track's duration, or zero — a small helper so the lyric tap can
/// seek by fraction.
extension AudioStateDuration on AppState {
  static Duration of(AppState state) => state.current?.duration ?? Duration.zero;
}
