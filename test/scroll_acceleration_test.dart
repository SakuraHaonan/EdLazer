import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/scrolling/scroll_motion.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/app_scroll_behavior.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/scroll_acceleration_setting.dart';

class _Gateway extends NeteaseGateway {
  @override
  Future<List<GatewaySong>> songDetails(List<int> ids) async => [];
}

class _Catalog extends Catalog {
  _Catalog() : super(gateway: _Gateway());
  @override
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => GatewayLyrics(
    lrc: [
      for (var i = 0; i < 30; i++)
        '[00:${(i * 2).toString().padLeft(2, '0')}]歌词 $i',
    ].join('\n'),
  );
}

class _SlowCatalog extends _Catalog {
  final request = Completer<HomeFeed?>();
  @override
  Future<HomeFeed?> loadHome({int? userId}) => request.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'saved acceleration applies before loading music; setters clamp and preserve inertia',
    () async {
      SharedPreferences.setMockInitialValues({
        'lazer_scroll_acceleration': 1.8,
      });
      final catalog = _SlowCatalog();
      final state = AppState(catalog: catalog);
      addTearDown(state.dispose);
      final values = <double>[];
      state.addListener(() => values.add(state.scrollAcceleration));
      final bootstrap = state.bootstrap();
      await Future<void>.delayed(Duration.zero);
      final beforeHome = List.of(values);
      catalog.request.complete(null);
      await bootstrap;
      expect(beforeHome, contains(1.8));
      await state.setScrollAcceleration(10);
      expect(state.scrollAcceleration, 3);
      await state.setScrollAcceleration(double.nan);
      expect(state.scrollAcceleration, 3);
      await state.setScrollAcceleration(0);
      expect(state.scrollAcceleration, .5);
      await state.setScrollAcceleration(2);
      expect(state.scrollRetention, ScrollMotion.defaultRetention);
      final restarted = AppState(catalog: _Catalog());
      addTearDown(restarted.dispose);
      await restarted.bootstrap();
      expect(restarted.scrollAcceleration, 2);
    },
  );

  testWidgets(
    'acceleration changes the active scroll physics, saves and resets on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        AnimatedBuilder(
          animation: state,
          builder: (context, _) => MaterialApp(
            theme: buildAppTheme(),
            scrollBehavior: AppScrollBehavior(
              retention: state.scrollRetention,
              acceleration: state.scrollAcceleration,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    ScrollAccelerationSetting(state: state),
                    Expanded(
                      child: ListView.builder(
                        controller: scroll,
                        itemCount: 100,
                        itemExtent: 60,
                        itemBuilder: (_, i) => Text('$i'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(AccessibleSlider), const Offset(70, 0));
      await tester.pumpAndSettle();
      expect(state.scrollAcceleration, greaterThan(1));
      expect(
        (scroll.position.physics as InertiaScrollPhysics).acceleration,
        state.scrollAcceleration,
      );
      expect(
        (await SharedPreferences.getInstance()).getDouble(
          'lazer_scroll_acceleration',
        ),
        state.scrollAcceleration,
      );
      await tester.tap(find.byKey(const ValueKey('scroll-acceleration-reset')));
      await tester.pumpAndSettle();
      expect(state.scrollAcceleration, 1);
      expect((scroll.position.physics as InertiaScrollPhysics).acceleration, 1);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'repeated flings use the gain and opposite wheel inputs brake within the speed limit',
    () {
      final low = const InertiaScrollPhysics(
        retention: .9,
        acceleration: .5,
      ).applyTo(const ClampingScrollPhysics());
      final high = const InertiaScrollPhysics(
        retention: .9,
        acceleration: 2,
      ).applyTo(const ClampingScrollPhysics());
      expect(
        high.carriedMomentum(1000),
        greaterThan(low.carriedMomentum(1000) * 3),
      );
      expect(high.retention, low.retention);
      expect(
        ScrollMotion.addWheelImpulse(200, -20, acceleration: 2),
        inExclusiveRange(0, 200),
      );
      expect(
        ScrollMotion.addWheelImpulse(200, -200, acceleration: 2),
        lessThan(0),
      );
      expect(ScrollMotion.addWheelImpulse(11900, 1200, acceleration: 3), 12000);
    },
  );

  testWidgets(
    'higher acceleration increases actual wheel travel in normal pages and lyrics',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Future<double> travel(double gain, {required bool lyrics}) async {
        final scroll = ScrollController(initialScrollOffset: 500);
        final state = AppState(catalog: _Catalog())..scrollAcceleration = gain;
        if (lyrics) {
          state.playQueue([
            const Track(
              id: '1',
              title: '歌',
              artist: '歌手',
              album: '专辑',
              duration: Duration(minutes: 2),
              coverSeed: 1,
            ),
          ]);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(),
            scrollBehavior: AppScrollBehavior(acceleration: gain),
            home: Scaffold(
              body: lyrics
                  ? LyricViewport(state: state)
                  : ListView.builder(
                      controller: scroll,
                      itemExtent: 60,
                      itemCount: 100,
                      itemBuilder: (_, i) => Text('$i'),
                    ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = lyrics
            ? tester.getTopLeft(find.text('歌词 0')).dy
            : scroll.offset;
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(200, 500),
            scrollDelta: Offset(0, 120),
          ),
        );
        await tester.pump();
        for (var i = 0; i < 25; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        final distance = lyrics
            ? before - tester.getTopLeft(find.text('歌词 0')).dy
            : scroll.offset - before;
        await tester.pumpWidget(const SizedBox.shrink());
        state.dispose();
        scroll.dispose();
        return distance;
      }

      for (final lyrics in [false, true]) {
        final low = await travel(1, lyrics: lyrics);
        final high = await travel(2, lyrics: lyrics);
        expect(low, greaterThan(0));
        expect(
          high,
          greaterThan(low * 1.8),
          reason: 'gain must affect ${lyrics ? 'lyrics' : 'ordinary lists'}',
        );
      }
    },
  );
}
