import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/lyrics.dart';
import '../data/models.dart';
import '../l10n/app_localizations.dart';
import '../theme/tokens.dart';
import '../utils/artwork.dart';
import '../utils/cover_save.dart';
import 'accessible_controls.dart';
import 'artwork_image.dart';
import 'interaction_feedback.dart';
import 'plate_art.dart';

Future<void> showLyricImageDialog(
  BuildContext context, {
  required Track track,
  required List<LyricLine> lines,
}) {
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  final bool dark = Theme.of(context).brightness == Brightness.dark;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: context.tr('关闭'),
    barrierColor: Colors.black.withValues(alpha: dark ? .62 : .32),
    transitionDuration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => themes.wrap(
      SafeArea(
        child: LyricImageDialog(track: track, lines: List.unmodifiable(lines)),
      ),
    ),
    transitionBuilder: (_, animation, _, child) {
      final eased = animation.drive(CurveTween(curve: Curves.easeOutCubic));
      return FadeTransition(
        opacity: eased,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, .035),
            end: Offset.zero,
          ).animate(eased),
          child: ScaleTransition(
            scale: Tween(begin: .96, end: 1.0).animate(eased),
            child: child,
          ),
        ),
      );
    },
  );
}

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
  final _previewScroll = ScrollController();
  ImageProvider? _artwork;
  bool _loading = true;
  bool _saving = false;
  bool _saved = false;
  bool _started = false;
  String? _error;

  Duration get _motion => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : const Duration(milliseconds: 240);

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
      _saved = false;
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
      if (mounted && saved) setState(() => _saved = true);
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请检查相册权限或稍后重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _preview() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return AnimatedSwitcher(
      duration: _motion,
      switchInCurve: AppMotion.emphasizedDecelerate,
      switchOutCurve: AppMotion.emphasizedAccelerate,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, .025),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          ),
      layoutBuilder: (Widget? current, List<Widget> previous) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          for (final Widget old in previous)
            ExcludeSemantics(child: IgnorePointer(child: old)),
          ?current,
        ],
      ),
      child: _loading
          ? Center(
              key: const ValueKey<String>('lyric-image-loading'),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      Icons.image_outlined,
                      size: 40,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 20),
                    const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '正在加载封面…',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Scrollbar(
              key: const ValueKey<String>('lyric-image-preview'),
              controller: _previewScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _previewScroll,
                padding: const EdgeInsets.all(12),
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
    );
  }

  Widget _status() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color tone = _error == null ? scheme.primary : scheme.error;
    return AnimatedSwitcher(
      duration: _motion,
      switchInCurve: AppMotion.emphasizedDecelerate,
      switchOutCurve: AppMotion.emphasizedAccelerate,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.topCenter,
            child: FadeTransition(opacity: animation, child: child),
          ),
      child: _error == null && !_saved
          ? const SizedBox.shrink(
              key: ValueKey<String>('lyric-image-status-empty'),
            )
          : Padding(
              key: ValueKey<String>(_error ?? 'saved'),
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      _error == null
                          ? Icons.check_circle_outline_rounded
                          : Icons.error_outline_rounded,
                      size: 18,
                      color: tone,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error ?? '歌词图片已保存',
                        style: theme.textTheme.bodySmall?.copyWith(color: tone),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _header() {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
      child: Row(
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: AppShape.mdRadius,
            ),
            child: Icon(
              Icons.image_outlined,
              size: 22,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '生成歌词图片',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.headlineSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AccessibleIconButton(
            tooltip: '关闭',
            onPressed: _saving ? null : () => Navigator.pop(context),
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    final back = TextButton(
      onPressed: _saving
          ? null
          : feedbackAction(context, () => Navigator.pop(context)),
      style: TextButton.styleFrom(enableFeedback: false),
      child: const TrText('返回选择', maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final save = _SaveImageButton(
      saving: _saving,
      saved: _saved,
      onPressed: _loading || _saving ? null : () => unawaited(_save()),
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _status(),
          if (MediaQuery.textScalerOf(context).scale(14) > 20)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[save, const SizedBox(height: 8), back],
            )
          else
            Row(
              children: <Widget>[
                back,
                const SizedBox(width: 12),
                Expanded(child: save),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return PopScope(
      canPop: !_saving,
      child: Dialog(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(borderRadius: AppShape.xxlRadius),
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 520,
          height: math.min(
            780,
            math.max(
              0,
              MediaQuery.sizeOf(context).height -
                  MediaQuery.paddingOf(context).vertical -
                  24,
            ),
          ),
          child: Column(
            children: <Widget>[
              _header(),
              Divider(height: 1, color: scheme.outlineVariant),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    children: <Widget>[
                      SizedBox(
                        width: double.infinity,
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          spacing: 12,
                          runSpacing: 4,
                          children: <Widget>[
                            Text(
                              '图片预览',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.onSurface,
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
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                            borderRadius: AppShape.mdRadius,
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: ClipRRect(
                            borderRadius: AppShape.mdRadius,
                            child: ShaderMask(
                              blendMode: BlendMode.dstIn,
                              shaderCallback: (Rect bounds) {
                                final double fade = math.min(
                                  .12,
                                  12 / math.max(1, bounds.height),
                                );
                                return LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: const <Color>[
                                    Colors.transparent,
                                    Colors.black,
                                    Colors.black,
                                    Colors.transparent,
                                  ],
                                  stops: <double>[0, fade, 1 - fade, 1],
                                ).createShader(bounds);
                              },
                              child: _preview(),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              _footer(),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _previewScroll.dispose();
    super.dispose();
  }
}

class _SaveImageButton extends StatefulWidget {
  const _SaveImageButton({
    required this.saving,
    required this.saved,
    required this.onPressed,
  });
  final bool saving, saved;
  final VoidCallback? onPressed;
  @override
  State<_SaveImageButton> createState() => _SaveImageButtonState();
}

class _SaveImageButtonState extends State<_SaveImageButton> {
  bool _pressed = false;

  void _press(bool value) {
    if (mounted && _pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Listener(
      onPointerDown: widget.onPressed == null ? null : (_) => _press(true),
      onPointerUp: (_) => _press(false),
      onPointerCancel: (_) => _press(false),
      child: AnimatedScale(
        scale: _pressed ? .97 : 1,
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : AppMotion.quick,
        curve: AppMotion.emphasizedDecelerate,
        child: FilledButton(
          onPressed: feedbackAction(context, widget.onPressed),
          style: FilledButton.styleFrom(
            backgroundColor: widget.saved
                ? scheme.secondaryContainer
                : scheme.primary,
            foregroundColor: widget.saved
                ? scheme.onSecondaryContainer
                : scheme.onPrimary,
            disabledBackgroundColor: scheme.surfaceContainerHighest,
            disabledForegroundColor: scheme.onSurfaceVariant,
            enableFeedback: false,
          ),
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : AppMotion.quick,
            switchInCurve: AppMotion.emphasizedDecelerate,
            switchOutCurve: AppMotion.emphasizedAccelerate,
            child: Row(
              key: ValueKey<(bool, bool)>((widget.saving, widget.saved)),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                widget.saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        widget.saved
                            ? Icons.check_rounded
                            : Icons.save_alt_rounded,
                        size: 18,
                      ),
                const SizedBox(width: 8),
                Flexible(
                  child: TrText(
                    widget.saving
                        ? '正在保存…'
                        : widget.saved
                        ? '再次保存'
                        : '保存图片',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        width: 360,
        child: ColoredBox(
          color: scheme.surfaceContainerLowest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 26, 18, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ClipRRect(
                  borderRadius: AppShape.mdRadius,
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: artwork == null
                        ? PlateArt(seed: track.coverSeed, size: 324)
                        : Image(image: artwork!, fit: BoxFit.cover),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  track.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontSize: 28,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  track.album,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Divider(height: 24, color: scheme.outlineVariant),
                for (var i = 0; i < lines.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 24),
                  Text(
                    lines[i].text.trim(),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontSize: 20,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (lines[i].translation?.trim().isNotEmpty ??
                      false) ...<Widget>[
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
