import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';

/// SMTC with timeline/seek support. All commands use the same AudioHandler as
/// Android, Apple platforms and MPRIS; native callbacks arrive on the UI thread.
class WindowsMediaPlatform extends AudioServicePlatform {
  static const channel = MethodChannel('dev.naominet.lazer/system_media');
  AudioHandlerCallbacks? _callbacks;
  Duration _duration = Duration.zero;
  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      _callbacks = callbacks;
  @override
  Future<void> configure(ConfigureRequest request) async {
    channel.setMethodCallHandler((call) async {
      final handler = _callbacks;
      if (handler == null) return;
      switch (call.method) {
        case 'play':
          await handler.play(const PlayRequest());
        case 'pause':
          await handler.pause(const PauseRequest());
        case 'next':
          await handler.skipToNext(const SkipToNextRequest());
        case 'previous':
          await handler.skipToPrevious(const SkipToPreviousRequest());
        case 'stop':
          await handler.stop(const StopRequest());
        case 'seek':
          await handler.seek(
            SeekRequest(
              position: Duration(milliseconds: call.arguments as int),
            ),
          );
      }
    });
    await channel.invokeMethod<void>('initialize');
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final item = request.mediaItem;
    _duration = item.duration ?? Duration.zero;
    await channel.invokeMethod<void>('metadata', {
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      'artPath':
          item.extras?['artCacheFile'] ??
          (item.artUri?.scheme == 'file' ? item.artUri!.toFilePath() : ''),
    });
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    final state = request.state;
    final actions = state.controls.map((control) => control.action).toSet();
    await channel.invokeMethod<void>('state', {
      'playing': state.playing,
      'enabled': state.processingState != AudioProcessingStateMessage.idle,
      'positionMs': state.updatePosition.inMilliseconds,
      'durationMs': _duration.inMilliseconds,
      'next': actions.contains(MediaActionMessage.skipToNext),
      'previous': actions.contains(MediaActionMessage.skipToPrevious),
    });
  }

  @override
  Future<void> setQueue(SetQueueRequest request) async {}
  @override
  Future<void> notifyChildrenChanged(
    NotifyChildrenChangedRequest request,
  ) async {}
  @override
  Future<void> stopService(StopServiceRequest request) =>
      channel.invokeMethod<void>('clear');
}
