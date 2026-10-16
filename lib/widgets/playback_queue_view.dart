import 'package:flutter/material.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import 'accessible_controls.dart';
import 'interaction_feedback.dart';
import 'plate_art.dart';

/// The same queue content can fill a desktop pane or a compact queue sheet.
class PlaybackQueueView extends StatefulWidget {
  const PlaybackQueueView({super.key, required this.state, this.onClose});
  final AppState state;
  final VoidCallback? onClose;
  @override
  State<PlaybackQueueView> createState() => _PlaybackQueueViewState();
}

class _PlaybackQueueViewState extends State<PlaybackQueueView> {
  ScrollController? _scroll;
  double get _rowExtent =>
      (MediaQuery.textScalerOf(context).scale(15) * 1.3 +
              MediaQuery.textScalerOf(context).scale(12) * 1.4 +
              23)
          .clamp(76, double.infinity);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll ??= ScrollController(
      initialScrollOffset:
          (widget.state.queue.indexWhere(
                    (track) => track.id == widget.state.current?.id,
                  ) -
                  2)
              .clamp(0, widget.state.queue.length) *
          _rowExtent,
    );
  }

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state,
    builder: (context, _) {
      final state = widget.state;
      return SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 8, 12),
              child: Row(
                children: [
                  Expanded(
                    child: SectionHeading('播放队列 · ${state.queue.length} 首'),
                  ),
                  if (widget.onClose != null)
                    AccessibleIconButton(
                      tooltip: '关闭',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: widget.onClose,
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                key: const PageStorageKey('playback-queue'),
                controller: _scroll,
                itemExtent: _rowExtent,
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
      );
    },
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
