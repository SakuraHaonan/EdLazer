import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/screens/player_page.dart';
import 'package:lazer_nextgen/screens/now_playing_page.dart';
import 'package:lazer_nextgen/screens/playlist_detail_page.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';

import 'support/serialized_semantics.dart';

const _track = Track(
  id: '901',
  title: 'Accessibility fixture',
  artist: 'Test',
  album: 'Test',
  duration: Duration(minutes: 2),
  coverSeed: 1,
);

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]歌词 $i',
    ].join('\n'),
    tlyric: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}.00]翻译 $i',
    ].join('\n'),
  );
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<List<Track>> playlistTracks(String id) async => [_track];
}

Future<void> _frames(WidgetTester tester, [int count = 30]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  final binding = RecordingSemanticsBinding();
  setUp(binding.recorder.reset);
  tearDown(() {
    binding.recorder.enabled = false;
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'recorder detects a rejected incremental update and retains the accepted tree',
    () {
      final recorder = SerializedSemanticsRecorder()..reset();
      recorder.commit({
        0: [1],
        1: [],
      });
      recorder.commit({2: []});
      expect(recorder.errors.single, contains('orphan=[2]'));
      recorder.commit({
        1: [3],
        3: [],
      });
      expect(recorder.errors, hasLength(1));
    },
  );

  testWidgets('pushed slider never serializes an orphan AXTree node', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('player')),
          body: const bool.fromEnvironment('REPRODUCE_FRAMEWORK_A11Y_BUG')
              ? Slider(value: .3, onChanged: (_) {})
              : AccessibleSlider(value: .3, onChanged: (_) {}),
        ),
      ),
    );
    await _frames(tester);
    expect(binding.recorder.commits, greaterThan(0));
    expect(binding.recorder.errors, isEmpty);
    semantics.dispose();
  });

  testWidgets(
    'dialog slider retains readout, keyboard and accessibility actions',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final sliderFocus = FocusNode();
      try {
        final navigator = GlobalKey<NavigatorState>();
        var value = .3;
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('home')),
          ),
        );
        await tester.pumpAndSettle();
        showDialog<void>(
          context: navigator.currentContext!,
          builder: (_) => AlertDialog(
            content: StatefulBuilder(
              builder: (context, setState) => AccessibleSlider(
                semanticLabel: '测试进度',
                focusNode: sliderFocus,
                value: value,
                divisions: 10,
                label: '$value',
                onChanged: (next) => setState(() => value = next),
              ),
            ),
          ),
        );
        await _frames(tester);
        final slider = find.byType(Slider);
        await tester.tap(slider);
        await _frames(tester, 4);
        SemanticsNode? sliderNode;
        void findSliderNode(SemanticsNode candidate) {
          if (sliderNode != null) return;
          if (candidate.getSemanticsData().flagsCollection.isSlider) {
            sliderNode = candidate;
          }
          candidate.visitChildren((child) {
            findSliderNode(child);
            return true;
          });
        }

        findSliderNode(tester.getSemantics(find.byType(AccessibleSlider)));
        expect(sliderNode, isNotNull);
        final node = sliderNode!;
        final data = node.getSemanticsData();
        expect(data.flagsCollection.isSlider, true);
        expect(data.label, contains('测试进度'));
        final beforeAction = value;
        node.owner!.performAction(node.id, ui.SemanticsAction.increase);
        await _frames(tester, 4);
        expect(value, greaterThan(beforeAction));
        final beforeKey = value;
        sliderFocus.requestFocus();
        await _frames(tester, 4);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await _frames(tester, 4);
        expect(value, greaterThan(beforeKey));
        final gesture = await tester.startGesture(tester.getCenter(slider));
        await gesture.moveBy(const Offset(20, 0));
        await _frames(tester, 15);
        await gesture.up();
        navigator.currentState!.pop();
        await _frames(tester);
        expect(binding.recorder.errors, isEmpty);
      } finally {
        semantics.dispose();
        sliderFocus.dispose();
      }
    },
  );

  testWidgets(
    'switching adjacent tooltip anchors in an indexed row stays connected',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final hover = await tester.createGesture(
        kind: ui.PointerDeviceKind.mouse,
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  Row(
                    children: [
                      AccessibleTooltip(
                        message: 'A',
                        child: const SizedBox(
                          width: 80,
                          height: 80,
                          child: Text('A'),
                        ),
                      ),
                      AccessibleIconButton(
                        tooltip: '播放队列 · 123 首',
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () {},
                      ),
                      AccessibleTooltip(
                        message: 'C',
                        child: const SizedBox(
                          width: 80,
                          height: 80,
                          child: Text('C'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await hover.addPointer(location: Offset.zero);
        for (var i = 0; i < 12; i++) {
          final label = ['A', '播放队列 · 123 首', 'C'][i % 3];
          final target = find.byTooltip(label);
          await hover.moveTo(tester.getCenter(target));
          tester.state<RawTooltipState>(target).ensureTooltipVisible();
          await _frames(tester, 12);
          if (i % 3 == 1) {
            expect(
              tester.getSize(find.text(label)).width,
              greaterThan(48),
              reason: 'tooltip text retains the full overlay width',
            );
          }
        }
        await hover.removePointer();
        Tooltip.dismissAllToolTips();
        await _frames(tester);
        expect(binding.recorder.errors, isEmpty);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'actual player, settings and lyric culling send valid incremental trees',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final state = AppState(catalog: _Catalog());
      final navigator = GlobalKey<NavigatorState>();
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        state.playQueue([_track]);
        await tester.pumpWidget(
          AnimatedBuilder(
            animation: state,
            builder: (context, _) => MaterialApp(
              navigatorKey: navigator,
              theme: buildAppTheme(),
              home: PlayerPage(state: state),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置'));
        await _frames(tester);
        await tester.ensureVisible(find.text('滚动惯性'));
        await _frames(tester);
        await tester.enterText(
          find.byKey(const ValueKey('scroll-inertia-input')),
          '97',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await _frames(tester);
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => NowPlayingPage(state: state)),
        );
        await tester.pumpAndSettle();
        for (var i = 1; i < 12; i++) {
          state.seek(i * 2 / 120);
          await _frames(tester, 16);
        }
        await tester.tap(find.byTooltip('播放队列'));
        await _frames(tester);
        await tester.tap(find.byTooltip('关闭'));
        await _frames(tester);
        await tester.longPress(find.text('歌词 11'));
        await _frames(tester);
        await tester.tap(find.text('全选'));
        await _frames(tester);
        await tester.tap(find.byTooltip('关闭'));
        await _frames(tester);
        expect(
          binding.recorder.errors,
          isEmpty,
          reason:
              'queue and lyric multiselect keep incremental semantics connected',
        );
        tester.view.physicalSize = const Size(390, 844);
        await _frames(tester);
        await tester.tap(find.byTooltip('歌词'));
        await _frames(tester, 45);
        tester
            .state<RawTooltipState>(find.byTooltip('歌词'))
            .ensureTooltipVisible();
        await _frames(tester, 200); // The header hides while its tooltip is up.
        expect(
          binding.recorder.errors,
          isEmpty,
          reason: 'tooltip anchors survive auto-hide',
        );
        await tester.drag(
          find.byType(AnimatedSwitcher).first,
          const Offset(0, -80),
        );
        await _frames(tester, 150);
        await tester.tapAt(const Offset(150, 180));
        await _frames(tester);
        navigator.currentState!.pop();
        await _frames(tester);
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => PlaylistDetailPage(
              state: state,
              playlist: const Playlist(
                id: '1',
                name: 'Test',
                trackIds: [],
                coverSeed: 1,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final tooltip = find.byTooltip('定位正在播放的歌曲');
        tester.state<RawTooltipState>(tooltip).ensureTooltipVisible();
        await _frames(tester, 12);
        await tester.tap(tooltip);
        await _frames(tester);
        tester.state<RawTooltipState>(tooltip).ensureTooltipVisible();
        await _frames(tester, 12);
        navigator.currentState!.pop();
        await _frames(tester);
        expect(
          binding.recorder.errors,
          isEmpty,
          reason: 'route pop with a visible tooltip',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(binding.recorder.commits, greaterThan(50));
        expect(binding.recorder.errors, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
        state.dispose();
      }
    },
  );
}
