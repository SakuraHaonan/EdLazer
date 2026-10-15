import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Playback surface used for stream URLs returned by the gateway.
abstract class AudioEngine {
  /// Whether a source is currently loaded.
  bool get active;

  Duration get position;
  Duration? get duration;

  Future<void> setUrl(String url);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> stop();

  /// Fires once each time the current source finishes playing.
  Stream<void> get completed;

  void dispose();
}

/// just_audio-backed engine used by the real app.
class JustAudioEngine implements AudioEngine {
  JustAudioEngine({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _completionSubscription = _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) _completionSent = false;
      if (state == ProcessingState.completed) _emitCompletion();
    });
  }

  final AudioPlayer _player;
  final StreamController<void> _completed = StreamController<void>.broadcast();
  late final StreamSubscription<ProcessingState> _completionSubscription;
  bool _hadSource = false;
  bool _completionSent = false;
  int _generation = 0;
  void _emitCompletion() {
    if (!_hadSource || _completionSent || _completed.isClosed) return;
    _completionSent = true;
    _completed.add(null);
  }

  @override
  bool get active => _hadSource;

  @override
  Duration get position => _player.position;

  @override
  Duration? get duration => _player.duration;

  @override
  Stream<void> get completed => _completed.stream;

  @override
  Future<void> setUrl(String url) async {
    final generation = ++_generation;
    _hadSource = false;
    _completionSent = false;
    final uri = Uri.parse(url);
    if (uri.scheme == 'file') {
      await _player.setFilePath(uri.toFilePath());
    } else {
      await _player.setUrl(url);
    }
    if (generation != _generation) return;
    _hadSource = true;
    if (_player.processingState == ProcessingState.completed) _emitCompletion();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) =>
      _player.setVolume(volume.clamp(0, 1));

  @override
  Future<void> stop() async {
    ++_generation;
    _hadSource = false;
    await _player.stop();
  }

  @override
  void dispose() {
    _completionSubscription.cancel();
    _completed.close();
    _player.dispose();
  }
}
