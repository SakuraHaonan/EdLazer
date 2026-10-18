import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';

/// Gates all publications, including delayed artwork from audio_service itself.
class SwitchableMediaPlatform extends AudioServicePlatform {
  SwitchableMediaPlatform(this.delegate, {this.toggleNative});

  final AudioServicePlatform delegate;
  final Future<void> Function(bool enabled)? toggleNative;
  bool _enabled = false;
  int _generation = 0;
  Future<void> _tail = Future<void>.value();

  Future<void> _send(Future<void> Function() operation) {
    final generation = _generation;
    final result = _tail.then((_) async {
      if (_enabled && generation == _generation) await operation();
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> setEnabled(bool enabled) {
    _enabled = false;
    final generation = ++_generation;
    final result = _tail.then((_) async {
      if (generation != _generation) return;
      if (toggleNative != null) {
        await toggleNative!(enabled);
      } else if (!enabled) {
        await delegate.stopService(const StopServiceRequest());
      }
      if (generation == _generation) _enabled = enabled;
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  @override
  Future<void> configure(ConfigureRequest request) =>
      delegate.configure(request);
  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) =>
      delegate.setHandlerCallbacks(callbacks);
  @override
  Future<void> setState(SetStateRequest request) =>
      _send(() => delegate.setState(request));
  @override
  Future<void> setQueue(SetQueueRequest request) =>
      _send(() => delegate.setQueue(request));
  @override
  Future<void> setMediaItem(SetMediaItemRequest request) =>
      _send(() => delegate.setMediaItem(request));
  @override
  Future<void> stopService(StopServiceRequest request) =>
      _send(() => delegate.stopService(request));
  @override
  Future<void> setAndroidPlaybackInfo(SetAndroidPlaybackInfoRequest request) =>
      _send(() => delegate.setAndroidPlaybackInfo(request));
  @override
  Future<void> androidForceEnableMediaButtons(
    AndroidForceEnableMediaButtonsRequest request,
  ) => _send(() => delegate.androidForceEnableMediaButtons(request));
  @override
  Future<void> notifyChildrenChanged(NotifyChildrenChangedRequest request) =>
      _send(() => delegate.notifyChildrenChanged(request));
}
