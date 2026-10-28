import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// The user-facing "歌词特效质量" setting.
enum LyricFxQuality { low, auto, high }

/// What the lyric viewport actually renders.
///
/// * [full]: distance blur, glyph glow, emphasis pulse, both edge masks.
/// * [reduced]: coarser, lower-resolution cached blur; no glyph glow.
/// * [minimal]: no blur, glow or pulse; a single vertical edge mask.
enum LyricFxTier { minimal, reduced, full }

/// Picks the lyric effect tier for [LyricFxQuality.auto] from real frame
/// timings.
///
/// Only frames rendered while a lyric viewport is animating are counted, so a
/// slow settings page or a cold start cannot demote the lyrics. A tier is
/// dropped when more than a quarter of the frames in a ~2 s window miss the
/// display's frame budget, and restored only after a long smooth stretch that
/// doubles after every demotion, so the tiers cannot oscillate.
class LyricFxGovernor extends ChangeNotifier {
  LyricFxGovernor._();
  static final LyricFxGovernor instance = LyricFxGovernor._();

  static const double _slowFactor = 1.2;
  static const double _demoteRatio = .25;
  static const double _smoothRatio = .05;
  static const int _baseRecoverWindows = 15;

  LyricFxTier _tier = LyricFxTier.full;
  LyricFxTier get tier => _tier;

  final Set<Object> _animating = <Object>{};
  bool _listening = false;
  int _frames = 0;
  int _slow = 0;
  int _smoothWindows = 0;
  int _demotions = 0;

  /// A viewport reports whether its ticker is running.
  void setAnimating(Object owner, bool animating) {
    if (animating) {
      _animating.add(owner);
      if (!_listening) {
        _listening = true;
        SchedulerBinding.instance.addTimingsCallback(_onTimings);
      }
    } else {
      _animating.remove(owner);
    }
  }

  void release(Object owner) => _animating.remove(owner);

  double get _refreshRate {
    try {
      final views = SchedulerBinding.instance.platformDispatcher.views;
      if (views.isEmpty) return 60;
      final double rate = views.first.display.refreshRate;
      return rate.isFinite && rate >= 30 ? math.min(rate, 165) : 60;
    } catch (_) {
      return 60;
    }
  }

  void _onTimings(List<FrameTiming> timings) {
    if (_animating.isEmpty) return;
    for (final FrameTiming frame in timings) {
      record(
        math.max(
          frame.buildDuration.inMicroseconds,
          frame.rasterDuration.inMicroseconds,
        ),
      );
    }
  }

  /// Feeds one frame's cost (the slower of build and raster, in µs).
  @visibleForTesting
  void record(int costMicros, {double? refreshRate}) {
    final double rate = refreshRate ?? _refreshRate;
    final double budget = 1e6 / rate;
    _frames++;
    if (costMicros > budget * _slowFactor) _slow++;
    final int window = (rate * 2).round();
    if (_frames < window) return;
    final double ratio = _slow / _frames;
    _frames = 0;
    _slow = 0;
    if (ratio > _demoteRatio) {
      _smoothWindows = 0;
      if (_tier != LyricFxTier.minimal) {
        _demotions++;
        _setTier(LyricFxTier.values[_tier.index - 1]);
      }
    } else if (ratio < _smoothRatio) {
      _smoothWindows++;
      final int needed = _baseRecoverWindows << math.min(_demotions, 3);
      if (_tier != LyricFxTier.full && _smoothWindows >= needed) {
        _smoothWindows = 0;
        _setTier(LyricFxTier.values[_tier.index + 1]);
      }
    } else {
      _smoothWindows = 0;
    }
  }

  void _setTier(LyricFxTier tier) {
    if (tier == _tier) return;
    _tier = tier;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _tier = LyricFxTier.full;
    _frames = 0;
    _slow = 0;
    _smoothWindows = 0;
    _demotions = 0;
    _animating.clear();
  }
}

LyricFxTier lyricFxTierFor(LyricFxQuality quality) => switch (quality) {
  LyricFxQuality.high => LyricFxTier.full,
  LyricFxQuality.low => LyricFxTier.minimal,
  LyricFxQuality.auto => LyricFxGovernor.instance.tier,
};
