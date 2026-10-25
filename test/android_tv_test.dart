import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lazer_nextgen/legacy/legacy_player_bar.dart';
import 'package:lazer_nextgen/tv/tv_mode.dart';

void main() {
  group('tv input', () {
    testWidgets('a tap target takes focus and activates with Select', (
      tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      int taps = 0;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: TvTapTarget(
                  focusNode: node,
                  onTap: () => taps++,
                  child: const SizedBox(
                    width: 120,
                    height: 48,
                    child: Center(child: Text('播放')),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(TvFocusOutline), findsNothing);

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(node.hasFocus, isTrue);
      expect(find.byType(TvFocusOutline), findsOneWidget);

      // A remote's centre button arrives as `select`.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap target stays inert off the television', (tester) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        TvScope(
          active: false,
          child: MaterialApp(
            home: Scaffold(
              body: TvTapTarget(
                focusNode: node,
                onTap: () {},
                child: const Text('播放'),
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(node.hasFocus, isFalse);
      expect(find.byType(TvFocusOutline), findsNothing);
    });

    testWidgets('the television alone gets overscan-safe insets', (
      tester,
    ) async {
      EdgeInsets? active;
      EdgeInsets? inactive;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: Builder(
            builder: (BuildContext context) {
              active = tvSafeInsets(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        TvScope(
          active: false,
          child: Builder(
            builder: (BuildContext context) {
              inactive = tvSafeInsets(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(active, const EdgeInsets.fromLTRB(24, 16, 24, 16));
      expect(inactive, EdgeInsets.zero);
    });

    testWidgets('left and right scrub the player seek rail', (tester) async {
      final List<double> seeks = <double>[];
      int committed = 0;
      await tester.pumpWidget(
        TvScope(
          active: true,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: LegacyThinSeekBar(
                    progress: .5,
                    onSeek: seeks.add,
                    onSeekFinished: () => committed++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final FocusNode node = Focus.of(
        tester.element(
          find
              .descendant(
                of: find.byType(LegacyThinSeekBar),
                matching: find.byType(Semantics),
              )
              .last,
        ),
      );
      node.requestFocus();
      await tester.pump();
      expect(
        node.canRequestFocus,
        isTrue,
        reason:
            'node=${node.debugLabel} primary=${FocusManager.instance.primaryFocus}',
      );
      expect(node.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(seeks.last, closeTo(.52, 1e-9));
      expect(committed, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(seeks.last, closeTo(.5, 1e-9));
      expect(committed, 2);

      // The pinned preview releases after the short commit window.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    test('overlay panels close in stack order', () {
      final TvOverlayStack stack = TvOverlayStack.instance;
      final List<String> closed = <String>[];
      void first() => closed.add('first');
      void second() => closed.add('second');
      stack.push(first);
      stack.push(second);
      expect(stack.hasOpen, isTrue);
      expect(stack.closeTop(), isTrue);
      expect(closed, <String>['second']);
      expect(stack.closeTop(), isTrue);
      expect(closed, <String>['second', 'first']);
      expect(stack.closeTop(), isFalse);
      expect(stack.hasOpen, isFalse);
    });
  });

  group('android tv packaging', () {
    test('the manifest is a Leanback launcher with a banner', () {
      final String manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android.software.leanback'));
      expect(manifest, contains('android.hardware.touchscreen'));
      expect(manifest, contains('android:required="false"'));
      expect(manifest, contains('LEANBACK_LAUNCHER'));
      expect(manifest, contains('android:banner="@drawable/tv_banner"'));
      expect(
        File(
          'android/app/src/main/res/drawable-xhdpi/tv_banner.png',
        ).existsSync(),
        isTrue,
        reason: 'the launcher banner must ship with the APK',
      );
    });
  });
}
