import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../audio/apple_motion_artwork.dart';

/// A cover that upgrades itself to Apple Music's animated artwork when the
/// album has one.
///
/// Everything here is optional: the static [child] paints immediately and stays
/// on screen unless a manifest resolves *and* the decoder actually starts
/// playing. Playback uses the platform decoder (Media Foundation on Windows,
/// AVFoundation on Apple platforms, ExoPlayer on Android), so it adds no
/// bundled codec libraries to the build.
class MotionArtwork extends StatefulWidget {
  const MotionArtwork({
    super.key,
    this.artist,
    this.album,
    this.size,
    required this.radius,
    required this.child,
  });

  final String? artist;
  final String? album;

  /// Fixed edge length; null fills the parent's box instead.
  final double? size;
  final double radius;

  /// Static cover, shown until the video is actually running.
  final Widget child;

  @override
  State<MotionArtwork> createState() => _MotionArtworkState();
}

class _MotionArtworkState extends State<MotionArtwork> {
  static final AppleMotionArtwork _lookup = AppleMotionArtwork();

  /// Linux has no `video_player` implementation, so only these try.
  static bool get _supported =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isIOS ||
          Platform.isAndroid);

  VideoPlayerController? _controller;
  String? _pending;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(MotionArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artist != widget.artist ||
        oldWidget.album != widget.album) {
      _teardown();
      unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }

  void _teardown() {
    final VideoPlayerController? controller = _controller;
    _controller = null;
    _pending = null;
    if (controller != null) unawaited(controller.dispose());
  }

  Future<void> _resolve() async {
    final String? artist = widget.artist;
    final String? album = widget.album;
    if (artist == null || album == null || artist.isEmpty || album.isEmpty) {
      return;
    }
    if (!_supported) return;

    final String key = '$artist|$album';
    _pending = key;
    final String? url = await _lookup.manifestFor(
      artist: artist,
      album: album,
    );
    if (!mounted || _pending != key || url == null) return;

    final VideoPlayerController controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
    );
    try {
      await controller.initialize();
      if (!mounted || _pending != key) {
        await controller.dispose();
        return;
      }
      await controller.setVolume(0);
      await controller.setLooping(true);
      await controller.play();
      if (!mounted || _pending != key) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      // Decoder rejected the stream: keep the static cover.
      await controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return widget.child;
    }
    final Size source = controller.value.size;
    if (source.width <= 0 || source.height <= 0) return widget.child;
    final Widget panel = ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: source.width,
          height: source.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
    final double? edge = widget.size;
    return edge == null
        ? SizedBox.expand(child: panel)
        : SizedBox(width: edge, height: edge, child: panel);
  }
}
