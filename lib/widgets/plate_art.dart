import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
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
    const fallback = ColoredBox(
      color: AppColors.manilla,
      child: Center(
        child: Icon(Icons.music_note_rounded, color: AppColors.cloudDark),
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
