import 'package:lazer_nextgen/theme/app_palette.dart';
import 'package:flutter/material.dart';

import '../utils/artwork.dart';
import 'artwork_image.dart';

/// Displays cached service artwork. Missing covers use a neutral music icon.
class PlateArt extends StatelessWidget {
  const PlateArt({
    super.key,
    required this.seed,
    this.accent = 0,
    this.radius,
    this.coverUrl,
  });

  final int seed;
  final int accent;
  final BorderRadius? radius;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) {
    final url = enlargedArtworkUrl(coverUrl);
    final fallback = ColoredBox(
      color: context.colors.manilla,
      child: Center(
        child: Icon(Icons.music_note_rounded, color: context.colors.cloudDark),
      ),
    );
    return ClipRRect(
      borderRadius: radius ?? BorderRadius.zero,
      child: url == null || url.isEmpty
          ? fallback
          : Image(
              image: ArtworkImage(url),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => fallback,
            ),
    );
  }
}
