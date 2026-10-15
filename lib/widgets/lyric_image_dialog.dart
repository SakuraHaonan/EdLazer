import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/lyrics.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_palette.dart';
import '../theme/paper_widgets.dart';
import '../utils/artwork.dart';
import '../utils/cover_save.dart';
import 'accessible_controls.dart';
import 'artwork_image.dart';
import 'plate_art.dart';

Future<void> showLyricImageDialog(
  BuildContext context, {
  required Track track,
  required List<LyricLine> lines,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      LyricImageDialog(track: track, lines: List.unmodifiable(lines)),
);

/// The preview itself is captured, so exported text wrapping matches exactly.
Future<Uint8List> captureLyricImage(RenderRepaintBoundary boundary) async {
  final size = boundary.size;
  // Keep long selections within texture and memory limits without truncating.
  final ratio = math.min(
    3.0,
    math.min(
      16000 / math.max(size.width, size.height),
      math.sqrt(16000000 / (size.width * size.height)),
    ),
  );
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}

class LyricImageDialog extends StatefulWidget {
  const LyricImageDialog({super.key, required this.track, required this.lines});
  final Track track;
  final List<LyricLine> lines;

  @override
  State<LyricImageDialog> createState() => _LyricImageDialogState();
}

class _LyricImageDialogState extends State<LyricImageDialog> {
  final _imageKey = GlobalKey();
  ImageProvider? _artwork;
  bool _loading = true;
  bool _saving = false;
  bool _started = false;
  String? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      unawaited(_loadArtwork());
    }
  }

  Future<void> _loadArtwork() async {
    final url = enlargedArtworkUrl(widget.track.coverUrl);
    if (url != null && url.isNotEmpty) {
      _artwork = ArtworkImage(url);
      await precacheImage(
        _artwork!,
        context,
        onError: (_, _) => _artwork = null,
      );
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    if (_saving || _loading) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final boundary =
          _imageKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final bytes = await captureLyricImage(boundary);
      if (!mounted) return;
      final saved = await saveCoverBytes(
        bytes,
        '${widget.track.title} - lyrics',
      );
      if (mounted && saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: TrText('歌词图片已保存')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查相册权限或稍后重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Dialog(
      backgroundColor: context.colors.ivoryMedium,
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height - 48,
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TrText('生成歌词图片', style: context.type.subheading),
                  ),
                  AccessibleIconButton(
                    tooltip: '关闭',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(48),
                        child: CircularProgressIndicator(),
                      )
                    : SingleChildScrollView(
                        child: SizedBox(
                          width: double.infinity,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.topCenter,
                            child: RepaintBoundary(
                              key: _imageKey,
                              child: LyricImageCard(
                                track: widget.track,
                                lines: widget.lines,
                                artwork: _artwork,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TrText(_error!, style: context.type.captionMuted),
                ),
              const SizedBox(height: 12),
              ClayButton(
                label: _saving ? '正在保存…' : '保存图片',
                onPressed: _loading || _saving
                    ? null
                    : () => unawaited(_save()),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A fixed-width, app-painted lyric sheet in the current application palette.
class LyricImageCard extends StatelessWidget {
  const LyricImageCard({
    super.key,
    required this.track,
    required this.lines,
    this.artwork,
  });
  final Track track;
  final List<LyricLine> lines;
  final ImageProvider? artwork;

  @override
  Widget build(BuildContext context) => MediaQuery.withNoTextScaling(
    child: SizedBox(
      width: 360,
      child: ColoredBox(
        color: context.colors.ivoryMedium,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 26, 18, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: artwork == null
                    ? PlateArt(seed: track.coverSeed)
                    : Image(image: artwork!, fit: BoxFit.cover),
              ),
              const SizedBox(height: 14),
              Text(
                track.title,
                style: context.type.heading.copyWith(
                  fontSize: 28,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                track.album,
                style: context.type.bodySm.copyWith(
                  color: context.colors.cloudDark,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                track.artist,
                style: context.type.bodySm.copyWith(
                  color: context.colors.cloudDark,
                ),
              ),
              Divider(height: 20, color: context.colors.cloudDark),
              for (var i = 0; i < lines.length; i++) ...[
                if (i > 0) const SizedBox(height: 24),
                Text(
                  lines[i].text.trim(),
                  style: context.type.body.copyWith(
                    fontSize: 20,
                    height: 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (lines[i].translation?.trim().isNotEmpty ?? false) ...[
                  const SizedBox(height: 4),
                  Text(
                    lines[i].translation!.trim(),
                    style: context.type.bodySm.copyWith(
                      fontSize: 14,
                      height: 1.5,
                      color: context.colors.cloudDark,
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
