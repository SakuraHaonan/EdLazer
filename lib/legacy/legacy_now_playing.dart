import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../state/app_state.dart';
import '../state/song_comments_controller.dart';
import '../state/ui_preferences.dart';
import '../utils/cover_save.dart';
import '../widgets/lyric_viewport.dart';
import '../widgets/playback_queue_view.dart';
import '../widgets/song_comments_view.dart';
import 'legacy_background.dart';
import 'legacy_login.dart';
import 'legacy_player_bar.dart' show LegacyThinSeekBar;
import 'legacy_theme.dart';
import 'legacy_widgets.dart';

/// The legacy now-playing page, ported from `NowPlayingPage` in the Lazer
/// mobile app (`shared/src/commonMain/.../LazerApp.kt`).
///
/// It keeps the mobile page's two compositions:
///
/// * Landscape (width > height): a 44% information column with a compact
///   artwork, the queue/comment actions and the transport, beside the lyric
///   sheet at 56%.
/// * Portrait: close and like in the header, title beside a small resting
///   artwork, the lyric sheet in the middle, and the transport at the bottom.
///
/// The same artwork is one node in both portrait states. Tapping it flies it
/// from the 52 dp header slot into the lyric area (420 ms, the legacy page
/// easing); tapping again returns it to the header. When a song has nothing to
/// sing the cover opens by itself, unless the listener has already chosen a
/// layout for that song. Long-pressing the artwork saves it, and long-pressing
/// the title or artist offers to copy it.
class LegacyNowPlayingPage extends StatefulWidget {
  const LegacyNowPlayingPage({super.key, required this.state});

  final AppState state;

  @override
  State<LegacyNowPlayingPage> createState() => _LegacyNowPlayingPageState();
}

class _LegacyNowPlayingPageState extends State<LegacyNowPlayingPage>
    with SingleTickerProviderStateMixin {
  static const Duration _coverFlight = Duration(milliseconds: 420);
  static const Cubic _motion = Cubic(0.2, 0, 0, 1);
  static const double _compactCover = 52;

  late final AnimationController _cover = AnimationController(
    vsync: this,
    duration: _coverFlight,
  );

  final GlobalKey _stackKey = GlobalKey();
  final GlobalKey _compactSlotKey = GlobalKey();
  final GlobalKey _expandedSlotKey = GlobalKey();

  Rect? _compactRect;
  Rect? _expandedRect;
  bool _measureQueued = false;
  bool _animationQueued = false;

  /// The listener's own choice. It survives track changes, as in the source.
  bool _coverExpanded = false;

  /// What the page is animating towards: the listener's choice or an
  /// automatic open for a song without lyrics.
  bool _coverOpen = false;

  /// Once a song's layout is picked, auto-open stops second-guessing it.
  bool _layoutPicked = false;

  String? _trackId;
  SongCommentsController? _comments;

  AppState get state => widget.state;

  @override
  void dispose() {
    _cover.dispose();
    _comments?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: state,
        builder: (BuildContext context, Widget? _) {
          final Track? track = state.current;
          if (track == null) return _emptyPage(context);
          _syncTrack(track);
          final Color page = legacyPageBackgroundOf(scheme);
          final bool backdrop =
              state.legacyBackground != LegacyBackgroundMode.off;
          final Size window = MediaQuery.sizeOf(context);
          final bool landscape = window.width > window.height;
          if (landscape) {
            // Rects belong to the portrait slots; drop them so a rotation
            // back measures fresh geometry instead of flying to stale points.
            _compactRect = null;
            _expandedRect = null;
          } else {
            _scheduleMeasure();
          }
          _syncCoverOpen();
          return Stack(
            key: _stackKey,
            fit: StackFit.expand,
            children: <Widget>[
              LegacyAlbumBackdrop(
                track: track,
                mode: state.legacyBackground,
                uiAlpha: state.legacyUiAlpha,
                pageColor: page,
                veil: backdrop ? page.withValues(alpha: 0.38) : null,
              ),
              SafeArea(
                child: landscape
                    ? _landscape(context, track)
                    : _portrait(context, track),
              ),
              if (!landscape) ?_coverOverlay(context, track),
            ],
          );
        },
      ),
    );
  }

  // -- portrait -------------------------------------------------------------

  Widget _portrait(BuildContext context, Track track) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              _closeButton(context, size: 48),
              const SizedBox(width: 12),
              SizedBox.square(
                dimension: _compactCover,
                key: _compactSlotKey,
                child: _overlayReady
                    ? const SizedBox.shrink()
                    : LegacyCover(
                        url: track.coverUrl,
                        radius: 12,
                        iconSize: 18,
                      ),
              ),
              Expanded(
                child: AnimatedBuilder(
                  animation: _cover,
                  builder: (BuildContext context, Widget? child) =>
                      Transform.translate(
                        offset: Offset(-_compactCover * _cover.value, 0),
                        child: child,
                      ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _title(context, track, centered: false),
                        if (track.translatedTitle?.trim().isNotEmpty ?? false)
                          Text(
                            track.translatedTitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        _artists(context, track, centered: false),
                      ],
                    ),
                  ),
                ),
              ),
              _likeButton(context, track),
            ],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double side = math
                    .min(
                      320.0,
                      math.min(constraints.maxWidth, constraints.maxHeight),
                    )
                    .clamp(0.0, 320.0);
                return Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // The resting cover's destination. It only reports its
                    // bounds; the shared artwork node paints on top.
                    Align(
                      alignment: Alignment.center,
                      child: SizedBox.square(
                        dimension: side,
                        key: _expandedSlotKey,
                      ),
                    ),
                    AnimatedBuilder(
                      animation: _cover,
                      builder: (BuildContext context, Widget? child) {
                        final double progress = _cover.value;
                        if (progress >= 0.999) {
                          return const SizedBox.shrink();
                        }
                        return IgnorePointer(
                          ignoring: _coverOpen,
                          child: Opacity(opacity: 1 - progress, child: child),
                        );
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 15),
                        child: LyricViewport(state: state),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: _controls(context, track, compact: false),
          ),
        ],
      ),
    );
  }

  bool get _overlayReady {
    final Rect? expanded = _expandedRect;
    return _compactRect != null &&
        expanded != null &&
        expanded.width > 0 &&
        expanded.height > 0;
  }

  Widget? _coverOverlay(BuildContext context, Track track) {
    final Rect? compact = _compactRect;
    final Rect? expanded = _expandedRect;
    if (compact == null ||
        expanded == null ||
        expanded.width <= 0 ||
        expanded.height <= 0) {
      return null;
    }
    final double endSize = math.min(expanded.width, expanded.height);
    final double startSize = math.min(_compactCover, endSize);
    final bool canSave = track.coverUrl?.isNotEmpty ?? false;
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _cover,
        builder: (BuildContext context, Widget? child) {
          final double progress = _cover.value;
          final double size = startSize + (endSize - startSize) * progress;
          final double left =
              compact.left + (expanded.left - compact.left) * progress;
          final double top =
              compact.top + (expanded.top - compact.top) * progress;
          final double radius = 12 + 12 * progress;
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: left,
                top: top,
                width: size,
                height: size,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    boxShadow: progress <= 0.01
                        ? null
                        : <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(
                                alpha: 0.38 * progress,
                              ),
                              blurRadius: 24 * progress,
                              offset: Offset(0, 12 * progress),
                            ),
                          ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(radius),
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
        child: Semantics(
          button: true,
          label: _coverOpen ? '显示歌词' : '展开封面',
          child: GestureDetector(
            key: const ValueKey<String>('legacy-now-playing-cover'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggleCover,
            onLongPress: canSave ? () => unawaited(_saveCover(track)) : null,
            child: LegacyCover(url: track.coverUrl, radius: 0, iconSize: 40),
          ),
        ),
      ),
    );
  }

  // -- landscape ------------------------------------------------------------

  Widget _landscape(BuildContext context, Track track) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double artworkSide = (constraints.maxHeight * 0.25).clamp(
            72.0,
            148.0,
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 44,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    child: SizedBox(
                      height: constraints.maxHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Column(
                          children: <Widget>[
                            SizedBox(
                              height: 44,
                              child: Row(
                                children: <Widget>[
                                  _closeButton(context, size: 40),
                                  const Spacer(),
                                  _likeButton(context, track),
                                ],
                              ),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    _artwork(
                                      context,
                                      track,
                                      size: artworkSide,
                                      radius: 18,
                                    ),
                                    const SizedBox(height: 6),
                                    _title(context, track, centered: true),
                                    if (track.translatedTitle
                                            ?.trim()
                                            .isNotEmpty ??
                                        false)
                                      Text(
                                        track.translatedTitle!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: _onSurfaceVariant(context),
                                            ),
                                      ),
                                    _artists(context, track, centered: true),
                                  ],
                                ),
                              ),
                            ),
                            _controls(context, track, compact: true),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 56,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: LyricViewport(state: state),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // -- shared pieces --------------------------------------------------------

  Widget _controls(BuildContext context, Track track, {required bool compact}) {
    final double side = compact ? 44 : 48;
    final double glyph = compact ? 27 : 30;
    final double playSide = compact ? 52 : 64;
    final double playGlyph = compact ? 29 : 34;
    return Padding(
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              _PlayerCardAction(
                icon: Icons.queue_music_rounded,
                label: '播放队列',
                onTap: () => unawaited(_openQueue()),
              ),
              const Spacer(),
              _PlayerCardAction(
                icon: Icons.mode_comment_outlined,
                label: '查看评论',
                onTap: () => unawaited(_openComments()),
              ),
            ],
          ),
          _NowPlayingSeek(
            key: ValueKey<String>('now-playing-seek-${track.id}-$compact'),
            state: state,
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _transportButton(
                context,
                icon: Icons.skip_previous_rounded,
                tooltip: '上一首',
                size: side,
                iconSize: glyph,
                onPressed: state.previous,
              ),
              SizedBox(width: compact ? 14 : 18),
              _transportButton(
                context,
                icon: state.playing
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                tooltip: state.playing ? '暂停' : '播放',
                size: playSide,
                iconSize: playGlyph,
                onPressed: state.togglePlay,
                primary: true,
              ),
              SizedBox(width: compact ? 14 : 18),
              _transportButton(
                context,
                icon: Icons.skip_next_rounded,
                tooltip: '下一首',
                size: side,
                iconSize: glyph,
                onPressed: state.next,
              ),
            ],
          ),
          // The landscape composition does not carry an error line in the
          // mobile source; the portrait sheet has room for it below the keys.
          if (!compact) _errorLine(context),
        ],
      ),
    );
  }

  Widget _artwork(
    BuildContext context,
    Track track, {
    required double size,
    required double radius,
  }) {
    final bool canSave = track.coverUrl?.isNotEmpty ?? false;
    return Semantics(
      image: true,
      label: '${track.title} 封面',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: canSave ? () => unawaited(_saveCover(track)) : null,
        child: SizedBox.square(
          dimension: size,
          child: LegacyCover(url: track.coverUrl, radius: radius, iconSize: 32),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, Track track, {required bool centered}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => unawaited(
        _requestCopy(
          title: '复制歌曲名',
          hint: '是否把《${track.title}》复制到剪贴板？',
          value: track.title,
        ),
      ),
      child: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: centered ? TextAlign.center : TextAlign.start,
        style: Theme.of(context).textTheme.titleMedium,
      ),
    );
  }

  Widget _artists(BuildContext context, Track track, {required bool centered}) {
    final String names = _artistNames(track);
    if (names.trim().isEmpty) return const SizedBox.shrink();
    final bool compact = !centered;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => unawaited(
        _requestCopy(title: '复制歌手名', hint: '是否把《$names》复制到剪贴板？', value: names),
      ),
      child: Text(
        names,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: centered ? TextAlign.center : TextAlign.start,
        style:
            (compact
                    ? Theme.of(context).textTheme.bodySmall
                    : Theme.of(context).textTheme.bodyMedium)
                ?.copyWith(color: _onSurfaceVariant(context)),
      ),
    );
  }

  Widget _closeButton(BuildContext context, {required double size}) {
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        visualDensity: VisualDensity.compact,
        iconSize: 24,
        tooltip: '收起播放器',
        onPressed: () {
          unawaited(state.feedback());
          Navigator.of(context).maybePop();
        },
        icon: const Icon(Icons.close_rounded),
      ),
    );
  }

  Widget _likeButton(BuildContext context, Track track) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool liked = state.currentLiked;
    return SizedBox.square(
      dimension: 44,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        visualDensity: VisualDensity.compact,
        tooltip: liked ? '移出我喜欢' : '加入我喜欢',
        onPressed: () => _toggleLike(),
        style: IconButton.styleFrom(
          foregroundColor: liked ? scheme.primary : scheme.onSurfaceVariant,
        ),
        icon: Icon(
          liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        ),
      ),
    );
  }

  Widget _transportButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required double size,
    required double iconSize,
    required VoidCallback onPressed,
    bool primary = false,
  }) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        visualDensity: VisualDensity.compact,
        iconSize: iconSize,
        tooltip: tooltip,
        onPressed: () {
          unawaited(state.feedback());
          onPressed();
        },
        style: IconButton.styleFrom(
          backgroundColor: primary ? scheme.primary : null,
          foregroundColor: primary ? scheme.onPrimary : scheme.onSurfaceVariant,
          disabledBackgroundColor: primary
              ? scheme.primary.withValues(alpha: 0.4)
              : null,
          disabledForegroundColor: primary
              ? scheme.onPrimary.withValues(alpha: 0.6)
              : scheme.onSurfaceVariant.withValues(alpha: 0.4),
        ),
        icon: Icon(icon, size: iconSize),
      ),
    );
  }

  Widget _errorLine(BuildContext context) {
    final String? message = state.playbackError ?? state.likeError;
    if (message == null || message.isEmpty) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
        ),
      ),
    );
  }

  Widget _emptyPage(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: legacyPageBackgroundOf(scheme)),
        SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _closeButton(context, size: 48),
                ),
              ),
              const Expanded(child: LegacyNotice(message: '还没有播放中的曲目。')),
            ],
          ),
        ),
      ],
    );
  }

  // -- state ----------------------------------------------------------------

  void _syncTrack(Track track) {
    if (_trackId == track.id) return;
    _trackId = track.id;
    // A lyric-less song may open its cover, but that is decided once per song.
    _layoutPicked = false;
  }

  void _syncCoverOpen() {
    final bool auto =
        !_layoutPicked && state.currentLyricsSettled && state.lyrics.isEmpty;
    final bool open = _coverExpanded || auto;
    if (open == _coverOpen) return;
    _coverOpen = open;
    _scheduleCoverAnimation();
  }

  void _scheduleCoverAnimation() {
    if (_animationQueued) return;
    _animationQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _animationQueued = false;
      if (mounted) _animateCoverTo(_coverOpen);
    });
  }

  void _animateCoverTo(bool open) {
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      _cover.value = open ? 1 : 0;
      return;
    }
    _cover.animateTo(open ? 1 : 0, duration: _coverFlight, curve: _motion);
  }

  void _toggleCover() {
    unawaited(state.feedback());
    setState(() {
      _layoutPicked = true;
      _coverExpanded = !_coverOpen;
      _coverOpen = _coverExpanded;
    });
    _animateCoverTo(_coverOpen);
  }

  void _scheduleMeasure() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (!mounted) return;
      final RenderBox? stack =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      if (stack == null) return;
      Rect? boundsOf(GlobalKey key) {
        final RenderBox? box =
            key.currentContext?.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return null;
        return box.localToGlobal(Offset.zero, ancestor: stack) & box.size;
      }

      final Rect? compact = boundsOf(_compactSlotKey);
      final Rect? expanded = boundsOf(_expandedSlotKey);
      if (compact == _compactRect && expanded == _expandedRect) return;
      setState(() {
        _compactRect = compact;
        _expandedRect = expanded;
      });
    });
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

  Future<void> _openQueue() async {
    unawaited(state.feedback());
    final ColorScheme scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (BuildContext sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.76,
        child: PlaybackQueueView(
          state: state,
          onClose: () => Navigator.of(sheet).pop(),
        ),
      ),
    );
  }

  Future<void> _openComments() async {
    final Track? track = state.current;
    if (track == null) return;
    unawaited(state.feedback());
    _comments ??= SongCommentsController(state.gateway);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: scheme.surface,
      barrierColor: Colors.black.withValues(alpha: 0.42),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (BuildContext sheet) => SizedBox(
        height: MediaQuery.sizeOf(sheet).height * 0.92,
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '评论',
                          style: Theme.of(sheet).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(sheet).textTheme.bodySmall?.copyWith(
                            color: Theme.of(sheet).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: 44,
                        height: 44,
                      ),
                      visualDensity: VisualDensity.compact,
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(sheet).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.7),
            ),
            Expanded(
              child: SongCommentsView(
                state: state,
                track: track,
                controller: _comments!,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestCopy({
    required String title,
    required String hint,
    required String value,
  }) async {
    unawaited(state.feedback());
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (BuildContext sheet) {
        final ThemeData theme = Theme.of(sheet);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(
                  hint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(sheet).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.of(sheet).pop(true),
                      child: const Text('复制'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
  }

  Future<void> _saveCover(Track track) async {
    final String? url = track.coverUrl;
    if (url == null || url.isEmpty) return;
    unawaited(state.feedback());
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool? confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (BuildContext sheet) {
        final ThemeData theme = Theme.of(sheet);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('保存封面图片', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 10),
                Text(
                  '是否保存《${track.title}》的封面图片？',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(sheet).pop(false),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: () => Navigator.of(sheet).pop(true),
                      child: const Text('保存图片'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      final bool saved = await saveCover(url, track.title);
      if (!mounted || !saved) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('《${track.title}》的封面已保存')));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('封面保存失败，请稍后重试')));
    }
  }
}

String _artistNames(Track track) {
  final List<String> names = <String>[
    for (final ArtistRef artist in track.artists)
      if (artist.id > 0 && artist.name.trim().isNotEmpty) artist.name.trim(),
  ];
  return names.isEmpty ? track.artist : names.join(' / ');
}

Color _onSurfaceVariant(BuildContext context) =>
    Theme.of(context).colorScheme.onSurfaceVariant;

/// The mobile seek rail: a thin track over a 48 dp hit strip, with the
/// buffered lead-in behind the played fraction. Dragging only previews; the
/// seek lands on release, as in the Compose page.
class _NowPlayingSeek extends StatefulWidget {
  const _NowPlayingSeek({super.key, required this.state});

  final AppState state;

  @override
  State<_NowPlayingSeek> createState() => _NowPlayingSeekState();
}

class _NowPlayingSeekState extends State<_NowPlayingSeek> {
  static const int _detents = 40;

  double? _drag;
  int? _detent;

  void _preview(double value) {
    setState(() => _drag = value);
    final int detent = (value * _detents).floor().clamp(0, _detents - 1);
    if (detent == _detent) return;
    _detent = detent;
    unawaited(widget.state.feedback(detent: true));
  }

  void _commit(double value) {
    setState(() {
      _drag = null;
      _detent = null;
    });
    unawaited(widget.state.feedback());
    widget.state.seek(value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextStyle? label = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
    );
    return AnimatedBuilder(
      animation: widget.state.ticks,
      builder: (BuildContext context, Widget? _) {
        final AppState state = widget.state;
        final double duration = (state.current?.duration.inMilliseconds ?? 0)
            .toDouble();
        final double live = duration > 0
            ? (state.precisePosition.inMilliseconds / duration).clamp(0.0, 1.0)
            : 0.0;
        final double fraction = (_drag ?? live).clamp(0.0, 1.0);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            LegacyThinSeekBar(
              progress: fraction,
              bufferedProgress: state.bufferedFraction,
              height: 48,
              semanticLabel: '播放进度',
              onSeek: duration <= 0 ? null : _preview,
              onSeekCommit: duration <= 0 ? null : _commit,
              onSeekFinished: () => setState(() => _drag = null),
            ),
            Row(
              children: <Widget>[
                Text(
                  legacyDuration(
                    Duration(milliseconds: (duration * fraction).round()),
                  ),
                  style: label,
                ),
                const Spacer(),
                Text(
                  legacyDuration(state.current?.duration ?? Duration.zero),
                  style: label,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A labelled card action: icon plus a short explanation of the sheet it
/// opens, so neither button is a mystery icon.
class _PlayerCardAction extends StatelessWidget {
  const _PlayerCardAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
