import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../utils/artwork.dart';
import 'artwork_image.dart';

/// Displays service artwork. Missing covers use a neutral music icon.
class PlateArt extends StatefulWidget {
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
  State<PlateArt> createState() => _PlateArtState();
}

class _PlateArtState extends State<PlateArt> {
  late List<String> _candidates = artworkCandidates(widget.coverUrl);
  int _attempt = 0;
  bool _retryScheduled = false;

  @override
  void didUpdateWidget(covariant PlateArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _candidates = artworkCandidates(widget.coverUrl);
      _attempt = 0;
      _retryScheduled = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // CDN-resized, https-normalized URL plus the headers the CDN demands:
    // `*.music.126.net` answers 403 to a request without a User-Agent.
    final String? url = _candidates.isEmpty ? null : _candidates[_attempt];
    final Widget fallback = ColoredBox(
      color: AppColors.manilla,
      child: const Center(
        child: Icon(Icons.music_note_rounded, color: AppColors.cloudDark),
      ),
    );
    return ClipRRect(
      borderRadius: widget.radius ?? BorderRadius.zero,
      child: url == null || url.isEmpty
          ? fallback
          : Image(
              image: ArtworkImage(url),
              fit: BoxFit.cover,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) {
                    if (error is NetworkImageLoadException &&
                        error.statusCode == 403 &&
                        _attempt + 1 < _candidates.length &&
                        !_retryScheduled) {
                      _retryScheduled = true;
                      final failedUrl = url;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (!mounted ||
                            _candidates.isEmpty ||
                            _candidates[_attempt] != failedUrl) {
                          return;
                        }
                        setState(() {
                          _attempt++;
                          _retryScheduled = false;
                        });
                      });
                    }
                    return fallback;
                  },
            ),
    );
  }
}
