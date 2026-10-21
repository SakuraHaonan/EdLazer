import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/models.dart';
import '../legacy/legacy_background.dart';
import '../utils/artwork.dart';
import '../utils/cover_save.dart';
import '../widgets/artwork_image.dart';
import 'lyric_document.dart';
import '../widgets/plate_art.dart';

/// Opens the lyric-image composer with an iOS-style scale/fade presentation.
Future<void> showLyricImageDialog(
  BuildContext context, {
  required Track track,
  required List<LyricLine> lines,
}) {
  final CapturedThemes themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: Colors.black.withValues(alpha: dark ? .64 : .34),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 280),
    pageBuilder: (_, _, _) => themes.wrap(
      SafeArea(
        child: LyricImageDialog(
          track: track,
          lines: List<LyricLine>.unmodifiable(lines),
        ),
      ),
    ),
    transitionBuilder: (_, Animation<double> animation, _, Widget child) {
      final Animation<double> eased = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: eased,
        child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1).animate(eased),
          child: child,
        ),
      );
    },
  );
}

/// Captures the exact preview tree, including content beyond the visible
/// scroll viewport. The pixel ratio is capped so very long selections stay
/// inside the engine's texture and memory limits.
Future<Uint8List> captureLyricImage(RenderRepaintBoundary boundary) async {
  final Size size = boundary.size;
  final double ratio = math.min(
    3,
    math.min(
      16000 / math.max(1, math.max(size.width, size.height)),
      math.sqrt(16000000 / math.max(1, size.width * size.height)),
    ),
  );
  final ui.Image image = await boundary.toImage(pixelRatio: ratio);
  try {
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

class LyricImageDialog extends StatefulWidget {
  const LyricImageDialog({
    super.key,
    required this.track,
    required this.lines,
  });

  final Track track;
  final List<LyricLine> lines;

  @override
  State<LyricImageDialog> createState() => _LyricImageDialogState();
}

class _LyricImageDialogState extends State<LyricImageDialog> {
  final GlobalKey _capture = GlobalKey();
  final ScrollController _previewScroll = ScrollController();
  ImageProvider? _artwork;
  Color? _coverSeed;
  bool _started = false;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_loadArtwork());
  }

  Future<void> _loadArtwork() async {
    final String? url = enlargedArtworkUrl(widget.track.coverUrl);
    if (url != null && url.isNotEmpty) {
      final ImageProvider provider = ArtworkImage(url);
      try {
        await precacheImage(provider, context);
        _artwork = provider;
        _coverSeed = await albumSeedForCover(widget.track.coverUrl);
      } catch (_) {
        _artwork = null;
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() {
      _saving = true;
      _saved = false;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final RenderRepaintBoundary? boundary =
          _capture.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('Preview is not ready');
      final Uint8List png = await captureLyricImage(boundary);
      if (!mounted) return;
      final bool saved = await saveCoverBytes(
        png,
        '${widget.track.title} - lyrics',
      );
      if (!mounted) return;
      setState(() {
        _saved = saved;
        if (!saved) _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saved = false;
          _error = '保存失败，请检查相册权限或稍后重试。';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _previewScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final double height = math.min(
      780,
      math.max(
        0,
        MediaQuery.sizeOf(context).height -
            MediaQuery.paddingOf(context).vertical -
            24,
      ),
    );
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        backgroundColor: scheme.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: 520,
          height: height,
          child: Column(
            children: <Widget>[
              _header(theme, scheme),
              Divider(height: .5, color: scheme.outlineVariant),
              Expanded(child: _previewArea(theme, scheme)),
              Divider(height: .5, color: scheme.outlineVariant),
              _footer(theme, scheme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 6, 14),
      child: Row(
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.image_outlined,
              size: 19,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '生成歌词图片',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  widget.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _saving ? null : () => Navigator.pop(context),
            iconSize: 19,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _previewArea(ThemeData theme, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '图片预览',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '已选择 ${widget.lines.length} 行',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _loading
                    ? Center(
                        key: const ValueKey<String>('lyric-image-loading'),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              '正在加载封面…',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Scrollbar(
                        controller: _previewScroll,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          key: const ValueKey<String>('lyric-image-preview'),
                          controller: _previewScroll,
                          padding: const EdgeInsets.all(12),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topCenter,
                            child: RepaintBoundary(
                              key: _capture,
                              child: LyricImageCard(
                                track: widget.track,
                                lines: widget.lines,
                                artwork: _artwork,
                                flowSeed: _coverSeed,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(ThemeData theme, ColorScheme scheme) {
    final Widget save = FilledButton(
      onPressed: _loading || _saving ? null : () => unawaited(_save()),
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        shape: const StadiumBorder(),
      ),
      child: Text(
        _saving ? '正在保存…' : (_saved ? '再次保存' : '保存图片'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    final Widget back = TextButton(
      onPressed: _saving ? null : () => Navigator.pop(context),
      child: const Text('返回选择', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_error != null || _saved) ...<Widget>[
            Row(
              children: <Widget>[
                Icon(
                  _error == null
                      ? Icons.check_circle_outline_rounded
                      : Icons.error_outline_rounded,
                  size: 17,
                  color: _error == null ? scheme.primary : scheme.error,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    _error ?? '歌词图片已保存',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _error == null ? scheme.primary : scheme.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool stack = constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20;
              if (stack) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[save, const SizedBox(height: 4), back],
                );
              }
              return Row(
                children: <Widget>[
                  back,
                  const SizedBox(width: 12),
                  Expanded(child: save),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The export card. Its width is fixed so exported line wrapping is stable
/// across phone, tablet and desktop previews.
class LyricImageCard extends StatelessWidget {
  const LyricImageCard({
    super.key,
    required this.track,
    required this.lines,
    this.artwork,
    this.flowSeed,
  });

  final Track track;
  final List<LyricLine> lines;
  final ImageProvider? artwork;
  final Color? flowSeed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    // The backdrop is sampled from the current cover. The hash tint is only
    // the stand-in used before that sample arrives, or when there is no art.
    final Color seed =
        flowSeed ??
        HSLColor.fromAHSL(
          1,
          (track.coverSeed.abs() * 47) % 360,
          .46,
          .48,
        ).toColor();
    final List<Color> colors = albumFlowColors(seed);
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        width: 360,
        child: CustomPaint(
          painter: _ExportBackdrop(
            surface: scheme.surfaceContainerLowest,
            colors: colors,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 24, 18, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox.square(
                    dimension: 324,
                    child: artwork == null
                        ? PlateArt(seed: track.coverSeed, size: 324)
                        : Image(image: artwork!, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  track.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 28,
                    height: 1.24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                if (track.album.isNotEmpty)
                  Text(
                    track.album,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Divider(height: 28, color: scheme.outlineVariant),
                for (int i = 0; i < lines.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 24),
                  Text(
                    lines[i].text.trim().isEmpty ? ' ' : lines[i].text.trim(),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 20,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (lines[i].translation?.trim().isNotEmpty ?? false) ...<
                    Widget
                  >[
                    const SizedBox(height: 4),
                    Text(
                      lines[i].translation!.trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 14,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ExportBackdrop extends CustomPainter {
  const _ExportBackdrop({required this.surface, required this.colors});

  final Color surface;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect bounds = Offset.zero & size;
    canvas.drawRect(bounds, Paint()..color = surface);
    canvas.save();
    canvas.clipRect(bounds.deflate(10));
    final double radius = math.max(size.width, size.height) * .7;
    for (final (int index, Offset center) in <(int, Offset)>[
      (1, Offset(size.width * .08, size.height * .12)),
      (3, Offset(size.width * .92, size.height * .88)),
    ]) {
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            radius,
            <Color>[
              colors[index].withValues(alpha: .56),
              colors[index].withValues(alpha: .16),
              colors[index].withValues(alpha: 0),
            ],
            const <double>[0, .48, 1],
          ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ExportBackdrop oldDelegate) =>
      oldDelegate.surface != surface ||
      oldDelegate.colors.length != colors.length ||
      <bool>[
        for (var i = 0; i < colors.length; i++)
          oldDelegate.colors[i] != colors[i],
      ].any((bool changed) => changed);
}
