import 'dart:async';

import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/audio/switchable_media_platform.dart';

class _Platform extends AudioServicePlatform {
  final calls = <String>[];
  Completer<void>? block;

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {
    calls.add(request.mediaItem.id);
    await block?.future;
  }

  @override
  Future<void> stopService(StopServiceRequest request) async {
    calls.add('clear');
  }
}

const _item = SetMediaItemRequest(
  mediaItem: MediaItemMessage(id: 'track', title: 'Track'),
);

void main() {
  test(
    'disabled gate drops delayed platform publications and clears after in-flight writes',
    () async {
      final delegate = _Platform();
      final platform = SwitchableMediaPlatform(delegate);
      await platform.setMediaItem(_item);
      expect(delegate.calls, isEmpty);
      await platform.setEnabled(true);
      delegate.block = Completer<void>();
      final publishing = platform.setMediaItem(_item);
      await Future<void>.delayed(Duration.zero);
      final disable = platform.setEnabled(false);
      final lateArtwork = platform.setMediaItem(_item);
      expect(delegate.calls, ['track']);
      delegate.block!.complete();
      await publishing;
      await disable;
      await lateArtwork;
      expect(delegate.calls, ['track', 'clear']);
      await platform.setEnabled(true);
      await platform.setMediaItem(_item);
      expect(delegate.calls, ['track', 'clear', 'track']);
    },
  );

  test('rapid flips converge to the final native setting', () async {
    final native = <bool>[];
    final platform = SwitchableMediaPlatform(
      _Platform(),
      toggleNative: (enabled) async => native.add(enabled),
    );
    final first = platform.setEnabled(true);
    final second = platform.setEnabled(false);
    final third = platform.setEnabled(true);
    await Future.wait([first, second, third]);
    expect(native, [true]);
  });
}
