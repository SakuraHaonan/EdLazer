import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:audio_service_mpris/metadata.dart';
import 'package:audio_service_mpris/mpris.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:dbus/dbus.dart';

/// Switchable MPRIS registration without rebuilding the AudioService handler.
class LinuxMediaPlatform extends AudioServicePlatform {
  LinuxMediaPlatform({bool enabled = true}) {
    _enabled = enabled;
  }

  bool _enabled = true;
  int _generation = 0;
  bool _isPlaying = false;
  ConfigureRequest? _configuration;
  AudioHandlerCallbacks? _callbacks;
  _MprisRegistration? _registration;
  Future<void> _lifecycle = Future<void>.value();

  /// Disabling rejects commands immediately, before asynchronous DBus teardown.
  Future<void> setEnabled(bool enabled) {
    if (_enabled != enabled) {
      _enabled = enabled;
      ++_generation;
    }
    return _serialize(enabled ? _open : _close);
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final result = _lifecycle.then((_) => operation());
    // A failed connection must not prevent a later disable or retry.
    _lifecycle = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  @override
  Future<void> configure(ConfigureRequest request) {
    _configuration = request;
    return _serialize(_open);
  }

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    _callbacks = callbacks;
  }

  Future<void> _open() async {
    final configuration = _configuration;
    if (!_enabled || configuration == null || _registration != null) return;
    final channelId = configuration.config.androidNotificationChannelId;
    if (channelId == null || channelId.isEmpty) {
      throw ArgumentError('androidNotificationChannelId is required for MPRIS');
    }

    final generation = _generation;
    final registration = _MprisRegistration(
      DBusClient.session(),
      OrgMprisMediaPlayer2(
        path: DBusObjectPath('/org/mpris/MediaPlayer2'),
        identity: configuration.config.androidNotificationChannelName,
      ),
      'org.mpris.MediaPlayer2.$channelId.instance$pid',
    );
    final mpris = registration.mpris;
    registration.subscriptions.addAll([
      mpris.controlStream.listen((event) {
        unawaited(
          _dispatch(registration, generation, (callbacks) async {
            switch (event) {
              case 'play':
                await callbacks.play(const PlayRequest());
              case 'pause':
                await callbacks.pause(const PauseRequest());
              case 'next':
                await callbacks.skipToNext(const SkipToNextRequest());
              case 'previous':
                await callbacks.skipToPrevious(const SkipToPreviousRequest());
              case 'stop':
                await callbacks.stop(const StopRequest());
              case 'playPause':
                if (_isPlaying) {
                  await callbacks.pause(const PauseRequest());
                } else {
                  await callbacks.play(const PlayRequest());
                }
            }
          }),
        );
      }),
      mpris.positionStream.listen((position) {
        unawaited(
          _dispatch(
            registration,
            generation,
            (callbacks) => callbacks.seek(SeekRequest(position: position)),
          ),
        );
      }),
      mpris.openUriStream.listen((uri) {
        unawaited(
          _dispatch(
            registration,
            generation,
            (callbacks) => callbacks.playFromUri(PlayFromUriRequest(uri: uri)),
          ),
        );
      }),
      mpris.volumeStream.listen((value) {
        unawaited(
          _dispatch(
            registration,
            generation,
            (callbacks) => callbacks.customAction(
              CustomActionRequest(name: 'dbusVolume', extras: {'value': value}),
            ),
          ),
        );
      }),
    ]);

    try {
      await registration.client.registerObject(mpris);
      registration.objectRegistered = true;
      if (!_enabled || generation != _generation) return;
      final reply = await registration.client.requestName(
        registration.name,
        flags: {DBusRequestNameFlag.doNotQueue},
      );
      registration.nameAcquired =
          reply == DBusRequestNameReply.primaryOwner ||
          reply == DBusRequestNameReply.alreadyOwner;
      if (!registration.nameAcquired) {
        throw StateError('MPRIS name is unavailable: ${registration.name}');
      }
      if (!_enabled || generation != _generation) return;
      _registration = registration;
    } finally {
      if (!identical(_registration, registration)) {
        await registration.close();
      }
    }
  }

  Future<void> _close() async {
    final registration = _registration;
    _registration = null;
    _isPlaying = false;
    await registration?.close();
  }

  Future<void> _dispatch(
    _MprisRegistration registration,
    int generation,
    Future<dynamic> Function(AudioHandlerCallbacks callbacks) command,
  ) async {
    final callbacks = _callbacks;
    if (!_enabled ||
        generation != _generation ||
        !identical(_registration, registration) ||
        callbacks == null) {
      return;
    }
    try {
      await command(callbacks);
    } catch (error, stackTrace) {
      log(
        'MPRIS command failed',
        name: 'LinuxMediaPlatform',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  Future<void> setState(SetStateRequest request) async {
    final registration = _registration;
    if (!_enabled || registration == null) return;
    final state = request.state;
    _isPlaying = state.playing;
    registration.mpris.position = state.updatePosition;
    registration.mpris.playbackState =
        state.processingState == AudioProcessingStateMessage.idle
        ? 'Stopped'
        : state.playing
        ? 'Playing'
        : 'Paused';
  }

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    final registration = _registration;
    if (!_enabled || registration == null) return;
    final item = request.mediaItem;
    registration.mpris.metadata = Metadata(
      title: item.title,
      length: item.duration,
      artist: item.artist == null ? null : [item.artist!],
      artUrl: item.artUri?.toString(),
      album: item.album,
      genre: item.genre == null ? null : [item.genre!],
    );
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    if (!_enabled) return;
    _isPlaying = false;
    _registration?.mpris.playbackState = 'Stopped';
  }

  @override
  Future<void> setQueue(SetQueueRequest request) async {}

  @override
  Future<void> notifyChildrenChanged(
    NotifyChildrenChangedRequest request,
  ) async {}

  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async {}
}

class _MprisRegistration {
  _MprisRegistration(this.client, this.mpris, this.name);

  final DBusClient client;
  final OrgMprisMediaPlayer2 mpris;
  final String name;
  final subscriptions = <StreamSubscription<dynamic>>[];
  bool objectRegistered = false;
  bool nameAcquired = false;

  Future<void> close() async {
    // Always close the transport, even if cancellation or releasing fails.
    try {
      await Future.wait(
        subscriptions.map((subscription) => subscription.cancel()),
      );
    } finally {
      try {
        if (nameAcquired) await client.releaseName(name);
      } finally {
        try {
          if (objectRegistered) await client.unregisterObject(mpris);
        } finally {
          await client.close();
        }
      }
    }
  }
}
