import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/widgets/copyable_song_title.dart';

void main() {
  testWidgets('long-pressing a song title asks before copying it', (
    WidgetTester tester,
  ) async {
    final List<String> copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            final Map<Object?, Object?> data =
                call.arguments as Map<Object?, Object?>;
            copied.add(data['text']! as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CopyableSongTitle(title: '夜航', child: Text('夜航')),
          ),
        ),
      ),
    );

    await tester.longPress(find.text('夜航'));
    await tester.pumpAndSettle();
    expect(find.text('是否复制歌曲名？'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    final Dialog dialog = tester.widget<Dialog>(find.byType(Dialog));
    final RoundedRectangleBorder shape =
        dialog.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(22));

    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(copied, <String>['夜航']);
    expect(find.text('已复制歌曲名'), findsOneWidget);
    expect(find.text('是否复制歌曲名？'), findsNothing);
  });
}
