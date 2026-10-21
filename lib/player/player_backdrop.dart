import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../legacy/legacy_background.dart';
import '../state/ui_preferences.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';

/// The immersive player canvas: album-colour flow + a real, heavily blurred
/// cover bloom + Apple Music's dark vignette.
class AlbumBlurFlow extends StatefulWidget {
  const AlbumBlurFlow({
    super.key,
    required this.track,
    required this.mode,
    required this.pageColor,
    this.animationsEnabled = true,
  });

  final Track? track;
  final LegacyBackgroundMode mode;
  final Color pageColor;
  final bool animationsEnabled;

  @override
  State<AlbumBlurFlow> createState() => _AlbumBlurFlowState();
}

class _AlbumBlurFlowState extends State<AlbumBlurFlow> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_updatePalette());
  }

  @override
  void didUpdateWidget(covariant AlbumBlurFlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_updatePalette());
    }
  }

  Future<void> _updatePalette() async {
    final int generation = ++_generation;
    final Color? seed = await albumSeedForCover(widget.track?.coverUrl);
    if (!mounted || generation != _generation) return;
    setState(() => _colors = albumFlowColors(seed ?? kAlbumDefaultSeed));
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ColoredBox(color: widget.pageColor),
            if (widget.mode != LegacyBackgroundMode.off)
              AlbumFlowBackground(
                colors: _colors,
                animated: widget.animationsEnabled &&
                    widget.mode == LegacyBackgroundMode.nowPlayingDynamic,
                solid: widget.mode == LegacyBackgroundMode.nowPlayingStatic,
              ),
            if (widget.animationsEnabled &&
                widget.mode != LegacyBackgroundMode.off &&
                (widget.track?.coverUrl?.isNotEmpty ?? false))
              _CoverBloom(url: widget.track!.coverUrl!),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      Color(0x99000000),
                      Color(0x22000000),
                      Color(0x44000000),
                      Color(0xE0000000),
                    ],
                    stops: <double>[0, .28, .62, 1],
                  ),
                ),
              ),
            ),
            const IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-.35, -.25),
                    radius: 1.08,
                    colors: <Color>[Color(0x00000000), Color(0x75000000)],
                    stops: <double>[.42, 1],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverBloom extends StatelessWidget {
  const _CoverBloom({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final String? resolved = artworkUrlForSize(
      url,
      logicalEdge: 192,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    if (resolved == null || resolved.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: ClipRect(
        child: Transform.scale(
          scale: 1.18,
          child: Opacity(
            opacity: .42,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Image(
                image: ArtworkImage(resolved),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder:
                    (
                      BuildContext context,
                      Object? error,
                      StackTrace? stackTrace,
                    ) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
