import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/utils/cover_save.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cover export writes the downloaded image and honors dialog cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lazer_cover_save_test_',
      );
      addTearDown(() async {
        await directory.delete(recursive: true);
      });
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aX1cAAAAASUVORK5CYII=',
      );
      final destination = File('${directory.path}/cover.png');
      bool cancel = false;
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'getSavePath');
        expect((call.arguments as Map)['suggestedName'], 'song_title.png');
        return cancel ? null : destination.path;
      });
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final result = await saveCoverBytes(png, 'song:title');
      expect(result, true);
      expect(await destination.readAsBytes(), png);
      cancel = true;
      expect(await saveCoverBytes(png, 'song:title'), false);
    },
    skip: Platform.isAndroid || Platform.isIOS,
  );
}
