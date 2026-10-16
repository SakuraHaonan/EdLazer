import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/widgets/lyric_text_hit_region.dart';

void main() {
  testWidgets(
    'wrapped short-line endings and line spacing pass through to the background',
    (tester) async {
      var lineTaps = 0, backgroundTaps = 0;
      const text = 'ABCDEFG';
      const style = TextStyle(fontSize: 20, height: 1.5);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => backgroundTaps++,
              child: Center(
                child: SizedBox(
                  width: 100,
                  child: LyricTextHitRegion(
                    text: text,
                    style: style,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => lineTaps++,
                      child: const Text(text, style: style),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      expect(boxes.length, 2);
      final last = boxes.last.toRect();
      await tester.tapAt(paragraph.localToGlobal(last.center));
      expect(lineTaps, 1);
      await tester.tapAt(paragraph.localToGlobal(Offset(90, last.center.dy)));
      expect(backgroundTaps, 1);
      await tester.tapAt(
        paragraph.localToGlobal(
          Offset(10, (boxes.first.bottom + last.top) / 2),
        ),
      );
      expect(backgroundTaps, 2);
      expect(lineTaps, 1);
    },
  );
}
