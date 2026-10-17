import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/models.dart';
import '../state/ui_preferences.dart';
import '../utils/artwork.dart';
import '../widgets/artwork_image.dart';
import 'legacy_theme.dart';

/// Ported from the Lazer project:
/// `shared/src/commonMain/.../AlbumFlowBackground.kt` (the flowing palette) and
/// `.../LazerBackgrounds.kt` (the artwork-seed extractor).
///
/// The album's dominant hue becomes a five-step ramp from a near-white tint to
/// a deep shade. Four of those colours drift across the page as large radial
/// gradients — each on its own orbit, scale pulse and rotation — while the
/// fifth paints the base and a slow overlay. A change of track crossfades the
/// whole palette instead of cutting.

/// Five colours derived from one seed, matching `flowColorsFromSeed`.
List<Color> albumFlowColors(Color seed) {
  final HSLColor hsl = HSLColor.fromColor(seed);
  final double chroma = (hsl.saturation * 0.72 + 0.12).clamp(0.20, 0.58);
  Color step(double saturation, double lightness) => HSLColor.fromAHSL(
    1,
    hsl.hue,
    saturation.clamp(0.0, 1.0),
    lightness.clamp(0.0, 1.0),
  ).toColor();
  return <Color>[
    step(chroma * 0.55, 0.90),
    step(chroma * 0.72, 0.76),
    step(chroma, 0.58),
    step(chroma * 0.86, 0.43),
    step(chroma * 0.74, 0.31),
  ];
}

/// The seed the legacy app starts from before any artwork is decoded.
const Color kAlbumDefaultSeed = LegacyTokens.lakeBlue;

/// `normalizeFlowPalette`: always five colours.
List<Color> normalizeFlowPalette(List<Color> colors) {
  if (colors.isEmpty) return albumFlowColors(kAlbumDefaultSeed);
  return List<Color>.generate(5, (int i) => colors[i % colors.length]);
}

/// One drifting gradient layer — the numbers are the legacy constants.
class _FlowLayer {
  const _FlowLayer({
    required this.paletteIndex,
    required this.phaseOffset,
    required this.speed,
    required this.orbitX,
    required this.orbitY,
    required this.scaleX,
    required this.scaleY,
    required this.rotationRange,
    this.colorAlpha = 0.68,
  });

  final int paletteIndex;
  final double phaseOffset;
  final double speed;
  final double orbitX;
  final double orbitY;
  final double scaleX;
  final double scaleY;
  final double rotationRange;
  final double colorAlpha;
}

const List<_FlowLayer> _flowLayers = <_FlowLayer>[
  _FlowLayer(
    paletteIndex: 0,
    phaseOffset: 0.2,
    speed: 0.19,
    orbitX: 0.30,
    orbitY: 0.24,
    scaleX: 1.68,
    scaleY: 1.18,
    rotationRange: 8,
  ),
  _FlowLayer(
    paletteIndex: 1,
    phaseOffset: 2.1,
    speed: 0.145,
    orbitX: 0.25,
    orbitY: 0.34,
    scaleX: 1.34,
    scaleY: 1.58,
    rotationRange: -10,
  ),
  _FlowLayer(
    paletteIndex: 2,
    phaseOffset: 4.0,
    speed: 0.17,
    orbitX: 0.37,
    orbitY: 0.20,
    scaleX: 1.52,
    scaleY: 1.26,
    rotationRange: 7,
  ),
  _FlowLayer(
    paletteIndex: 3,
    phaseOffset: 5.35,
    speed: 0.12,
    orbitX: 0.20,
    orbitY: 0.38,
    scaleX: 1.28,
    scaleY: 1.62,
    rotationRange: -6,
  ),
  _FlowLayer(
    paletteIndex: 4,
    phaseOffset: 1.25,
    speed: 0.105,
    orbitX: 0.16,
    orbitY: 0.18,
    scaleX: 1.85,
    scaleY: 1.12,
    rotationRange: 5,
    colorAlpha: 0.52,
  ),
];

/// The animated album-colour renderer.
class AlbumFlowBackground extends StatefulWidget {
  const AlbumFlowBackground({
    super.key,
    required this.colors,
    this.veil = const Color(0x00000000),
    this.animated = true,
    this.solid = false,
    this.cornerRadius = 0,
  });

  final List<Color> colors;

  /// Tinted veil composited over the flow; transparent leaves it untouched.
  final Color veil;

  /// `false` freezes the layers, matching the legacy "static" mode.
  final bool animated;

  /// `true` paints the base colour only.
  final bool solid;

  final double cornerRadius;

  @override
  State<AlbumFlowBackground> createState() => _AlbumFlowBackgroundState();
}

class _AlbumFlowBackgroundState extends State<AlbumFlowBackground>
    with TickerProviderStateMixin {
  static const Duration _paletteFade = Duration(milliseconds: 650);
  static const double _frameInterval = 1 / 30;

  late List<Color> _from = normalizeFlowPalette(widget.colors);
  late List<Color> _to = _from;
  late final AnimationController _palette = AnimationController(
    vsync: this,
    duration: _paletteFade,
    value: 1,
  );
  final ValueNotifier<int> _frames = ValueNotifier<int>(0);
  Ticker? _ticker;
  double _phase = 0;
  double _pending = 0;
  Duration _last = Duration.zero;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _syncPlayback();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool reduce =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      _syncPlayback();
    }
  }

  @override
  void didUpdateWidget(AlbumFlowBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final List<Color> next = normalizeFlowPalette(widget.colors);
    if (!_samePalette(next, _to)) {
      _from = _currentPalette();
      _to = next;
      if (_reduceMotion) {
        _palette.value = 1;
      } else {
        _palette.forward(from: 0);
      }
    }
    if (oldWidget.animated != widget.animated) _syncPlayback();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _palette.dispose();
    _frames.dispose();
    super.dispose();
  }

  void _syncPlayback() {
    final bool run = widget.animated && !_reduceMotion && !widget.solid;
    if (run) {
      _ticker ??= createTicker(_onTick)..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _onTick(Duration elapsed) {
    if (_last == Duration.zero) {
      _last = elapsed;
      return;
    }
    final double delta =
        (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    _pending += delta.clamp(0.0, 0.1);
    if (_pending < _frameInterval) return;
    _phase = (_phase + _pending) % 10000;
    _pending = 0;
    _frames.value++;
  }

  List<Color> _currentPalette() {
    final double t = _fluidEase(_palette.value);
    return List<Color>.generate(
      5,
      (int i) => Color.lerp(_from[i], _to[i], t) ?? _to[i],
    );
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.cornerRadius),
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_palette, _frames]),
          builder: (BuildContext context, Widget? _) {
            final List<Color> palette = _currentPalette();
            final String tag = widget.solid ? 'solid' : 'flow';
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Size size = constraints.biggest;
                if (!size.isFinite || size.isEmpty) {
                  return ColoredBox(color: palette[4], key: ValueKey<String>(tag));
                }
                return Stack(
                  key: ValueKey<String>(tag),
                  fit: StackFit.expand,
                  children: <Widget>[
                    ColoredBox(color: palette[4]),
                    if (!widget.solid)
                      for (final _FlowLayer layer in _flowLayers)
                        _flowLayerBox(layer, palette[layer.paletteIndex], size),
                    if (widget.veil.a > 0) ..._veil(),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _flowLayerBox(_FlowLayer layer, Color color, Size size) {
    final double time = _phase * layer.speed + layer.phaseOffset;
    final double secondary = _phase * layer.speed * 0.73 + layer.phaseOffset * 1.37;
    final double pulse = math.sin(time * 0.61) * 0.075;
    final double alpha = layer.colorAlpha;
    return Transform.translate(
      offset: Offset(
        math.sin(time) * size.width * layer.orbitX,
        math.cos(secondary) * size.height * layer.orbitY,
      ),
      child: Transform.rotate(
        angle: math.sin(time * 0.43) * layer.rotationRange * math.pi / 180,
        child: Transform.scale(
          scaleX: layer.scaleX + pulse,
          scaleY: layer.scaleY - pulse * 0.72,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.5,
                colors: <Color>[
                  color.withValues(alpha: alpha),
                  color.withValues(alpha: alpha * 0.56),
                  color.withValues(alpha: alpha * 0.16),
                  color.withValues(alpha: 0),
                ],
                stops: const <double>[0, 1 / 3, 2 / 3, 1],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _veil() {
    final Color veil = widget.veil;
    return <Widget>[
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: <Color>[
              veil.withValues(alpha: 0),
              veil.withValues(alpha: veil.a * 0.28),
              veil.withValues(alpha: veil.a * 0.72),
            ],
            stops: const <double>[0, 0.5, 1],
          ),
        ),
      ),
      ColoredBox(color: veil.withValues(alpha: veil.a * 0.72)),
    ];
  }
}

double _fluidEase(double fraction) {
  final double f = fraction.clamp(0.0, 1.0);
  return (1 - math.cos(math.pi * f)) / 2;
}

bool _samePalette(List<Color> a, List<Color> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Artwork seed extraction (LazerBackgrounds.kt)
// ---------------------------------------------------------------------------

final Map<String, Color> _seedCache = <String, Color>{};

/// Samples the artwork down to 48×48 and picks the dominant *vibrant* hue,
/// boosting its saturation — the legacy `seedFromArtwork`.
Color albumSeedFromPixels(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0) return kAlbumDefaultSeed;
  final int stepX = math.max(1, width ~/ 48);
  final int stepY = math.max(1, height ~/ 48);
  final List<double> red = List<double>.filled(24, 0);
  final List<double> green = List<double>.filled(24, 0);
  final List<double> blue = List<double>.filled(24, 0);
  final List<double> weights = List<double>.filled(24, 0);
  double averageRed = 0, averageGreen = 0, averageBlue = 0;
  double averageCount = 0;
  for (int y = 0; y < height; y += stepY) {
    for (int x = 0; x < width; x += stepX) {
      final int index = (y * width + x) * 4;
      if (index + 3 >= rgba.length) continue;
      if (rgba[index + 3] < 128) continue;
      final int r = rgba[index];
      final int g = rgba[index + 1];
      final int b = rgba[index + 2];
      averageRed += r;
      averageGreen += g;
      averageBlue += b;
      averageCount++;
      final HSLColor hsl = HSLColor.fromColor(
        Color.fromARGB(255, r, g, b),
      );
      final double saturation = hsl.saturation;
      final double lightness = hsl.lightness;
      if (saturation >= 0.15 && lightness >= 0.12 && lightness <= 0.92) {
        final double weight =
            saturation * math.max(0.05, 1.0 - (lightness - 0.5).abs() * 1.6);
        final int bucket = math.min(23, (hsl.hue / 360 * 24).toInt());
        red[bucket] += r * weight;
        green[bucket] += g * weight;
        blue[bucket] += b * weight;
        weights[bucket] += weight;
      }
    }
  }
  int best = 0;
  for (int i = 1; i < weights.length; i++) {
    if (weights[i] > weights[best]) best = i;
  }
  if (weights[best] > 0.5) {
    final Color seed = Color.fromARGB(
      255,
      (red[best] / weights[best]).round().clamp(0, 255),
      (green[best] / weights[best]).round().clamp(0, 255),
      (blue[best] / weights[best]).round().clamp(0, 255),
    );
    final HSLColor hsl = HSLColor.fromColor(seed);
    return HSLColor.fromAHSL(
      1,
      hsl.hue,
      math.min(1, hsl.saturation * 1.25),
      hsl.lightness,
    ).toColor();
  }
  if (averageCount > 0) {
    return Color.fromARGB(
      255,
      (averageRed / averageCount).round().clamp(0, 255),
      (averageGreen / averageCount).round().clamp(0, 255),
      (averageBlue / averageCount).round().clamp(0, 255),
    );
  }
  return kAlbumDefaultSeed;
}

/// A 96 px rendition of the cover — enough for a palette, cheap to fetch.
String? albumPaletteArtworkUrl(String? raw) {
  final String? normalized = normalizedArtworkUrl(raw);
  if (normalized == null) return null;
  final RegExp param = RegExp(r'([?&]param=)\d+y\d+', caseSensitive: false);
  if (param.hasMatch(normalized)) {
    return normalized.replaceAllMapped(
      param,
      (Match match) => '${match.group(1)}96y96',
    );
  }
  return normalized +
      (normalized.contains('?') ? '&param=96y96' : '?param=96y96');
}

/// Extracts (and caches) the seed colour for a cover, or null when the artwork
/// cannot be decoded.
Future<Color?> albumSeedForCover(String? coverUrl) async {
  final String? url = albumPaletteArtworkUrl(coverUrl);
  if (url == null) return null;
  final Color? cached = _seedCache[url];
  if (cached != null) return cached;
  final ui.Image? image = await _decode(ArtworkImage(url));
  if (image == null) return null;
  try {
    final ByteData? pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (pixels == null) return null;
    final Color seed = albumSeedFromPixels(
      pixels.buffer.asUint8List(),
      image.width,
      image.height,
    );
    if (_seedCache.length >= 24) {
      _seedCache.remove(_seedCache.keys.first);
    }
    _seedCache[url] = seed;
    return seed;
  } finally {
    image.dispose();
  }
}

Future<ui.Image?> _decode(ImageProvider provider) {
  final Completer<ui.Image?> completer = Completer<ui.Image?>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool synchronousCall) {
      if (!completer.isCompleted) completer.complete(info.image);
      stream.removeListener(listener);
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.complete(null);
      stream.removeListener(listener);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// The album-tinted page backdrop: flowing palette derived from the current
/// track, softened by the content-opacity veil.
class LegacyAlbumBackdrop extends StatefulWidget {
  const LegacyAlbumBackdrop({
    super.key,
    required this.track,
    required this.mode,
    required this.uiAlpha,
    this.veil,
    this.pageColor,
  });

  final Track? track;
  final LegacyBackgroundMode mode;

  /// `内容不透明度` — 0.4 … 1.0. The veil over the palette is its square.
  final double uiAlpha;

  /// When set, the flow carries this veil itself and no content scrim is drawn
  /// — the now-playing page uses the legacy `background @ 0.38`.
  final Color? veil;

  /// Painted under the flow (legacy `colors.background`), and on its own when
  /// the backdrop is off.
  final Color? pageColor;

  @override
  State<LegacyAlbumBackdrop> createState() => _LegacyAlbumBackdropState();
}

class _LegacyAlbumBackdropState extends State<LegacyAlbumBackdrop> {
  List<Color> _colors = albumFlowColors(kAlbumDefaultSeed);
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(LegacyAlbumBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track?.id != widget.track?.id ||
        oldWidget.track?.coverUrl != widget.track?.coverUrl) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    final Color? seed = await albumSeedForCover(widget.track?.coverUrl);
    if (!mounted || generation != _generation) return;
    setState(() => _colors = albumFlowColors(seed ?? kAlbumDefaultSeed));
  }

  @override
  Widget build(BuildContext context) {
    final Color? pageColor = widget.pageColor;
    if (widget.mode == LegacyBackgroundMode.off) {
      return pageColor == null
          ? const SizedBox.shrink()
          : ColoredBox(color: pageColor);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double veil = (widget.uiAlpha * widget.uiAlpha).clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (pageColor != null) ColoredBox(color: pageColor),
        AlbumFlowBackground(
          colors: _colors,
          animated: widget.mode == LegacyBackgroundMode.nowPlayingDynamic,
          solid: widget.mode == LegacyBackgroundMode.nowPlayingStatic,
          veil: widget.veil ?? const Color(0x00000000),
        ),
        if (widget.veil == null)
          ColoredBox(color: scheme.surface.withValues(alpha: veil)),
      ],
    );
  }
}
