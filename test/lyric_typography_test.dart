import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lazer_nextgen/data/catalog.dart';
import 'package:lazer_nextgen/data/models.dart';
import 'package:lazer_nextgen/gateway/gateway.dart';
import 'package:lazer_nextgen/state/app_state.dart';
import 'package:lazer_nextgen/theme/app_theme.dart';
import 'package:lazer_nextgen/widgets/accessible_controls.dart';
import 'package:lazer_nextgen/widgets/lyric_typography_setting.dart';
import 'package:lazer_nextgen/widgets/lyric_viewport.dart';
import 'package:lazer_nextgen/widgets/timed_lyric_text.dart';

const _track = Track(
  id: '1',
  title: '歌曲',
  artist: '歌手',
  album: '专辑',
  albumId: 77,
  artists: [ArtistRef(id: 11, name: '歌手')],
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
  Future<HomeFeed?> loadHome({int? userId}) async => null;
  @override
  Future<String?> audioUrlFor(Track track) async => null;
  @override
  Future<GatewayLyrics?> lyricsFor(Track track) async => const GatewayLyrics(
    yrc: '[0,5000](0,5000,0)这一行歌词会随着字号变化重新换行和定位\n[5000,5000](5000,5000,0)第二行歌词',
    tlyric: '[00:00]Translation of this line\n[00:05]Second line',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'typography is clamped, persisted and restored alongside artist identities in the queue',
    () async {
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await state.setLyricFontSize(100);
      expect(state.lyricFontSize, 40);
      await state.setLyricFontSize(double.nan);
      expect(state.lyricFontSize, 40);
      await state.setLyricFontSize(1);
      expect(state.lyricFontSize, 14);
      await state.setLyricFontSize(30);
      await state.setLyricFontWeight(50);
      expect(state.lyricFontWeight, 400);
      await state.setLyricFontWeight(999);
      expect(state.lyricFontWeight, 700);
      await state.setLyricFontWeight(540);
      state.playQueue([_track]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final restarted = AppState(catalog: _Catalog());
      addTearDown(restarted.dispose);
      await restarted.bootstrap();
      expect(restarted.lyricFontSize, 30);
      expect(restarted.lyricFontWeight, 500);
      expect(restarted.current!.albumId, 77);
      expect(restarted.current!.artists.single.id, 11);
    },
  );

  testWidgets(
    'settings update the preview and save font choices on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: LyricTypographySetting(state: state),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(AccessibleSlider), const Offset(80, 0));
      await tester.pumpAndSettle();
      expect(state.lyricFontSize, greaterThan(22));
      await tester.tap(find.text('粗体'));
      await tester.pumpAndSettle();
      final preview = tester.widget<AnimatedDefaultTextStyle>(
        find.byType(AnimatedDefaultTextStyle).last,
      );
      expect(preview.style.fontSize, state.lyricFontSize);
      expect(preview.style.fontWeight, FontWeight.w700);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('lazer_lyric_font_size'), state.lyricFontSize);
      expect(prefs.getInt('lazer_lyric_font_weight'), 700);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'live typography changes reflow timed lyrics and preserve the selected lines',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final state = AppState(catalog: _Catalog());
      addTearDown(state.dispose);
      state.playQueue([_track]);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(body: LyricViewport(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byType(TimedLyricText).first;
      final before = tester.getSize(first).height;
      await tester.longPressAt(
        tester
            .renderObject<RenderBox>(first)
            .localToGlobal(const Offset(12, 16)),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 行'), findsOneWidget);
      await state.setLyricFontSize(38);
      await state.setLyricFontWeight(700);
      await tester.pumpAndSettle();
      final text = tester.widget<TimedLyricText>(
        find.byType(TimedLyricText).first,
      );
      expect(text.style.fontSize, 38);
      expect(text.style.fontWeight, FontWeight.w700);
      expect(
        tester.getSize(find.byType(TimedLyricText).first).height,
        greaterThan(before),
      );
      expect(find.text('已选择 1 行'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
