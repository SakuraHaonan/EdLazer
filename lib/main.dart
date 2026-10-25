import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio/audio_engine.dart';
import 'audio/system_media_handler.dart';
import 'audio/playback_session.dart';
import 'diagnostics/frame_stats.dart';
import 'legacy/legacy_shell.dart';
import 'theme/apple_design.dart';
import 'state/app_state.dart';
import 'tv/tv_mode.dart';
import 'widgets/window_frame.dart';
import 'widgets/interaction_feedback.dart';
import 'widgets/app_scroll_behavior.dart';
import 'widgets/ui_scaling.dart';

/// Lines the media backend prints that we cannot silence upstream.
///
/// `just_audio_media_kit` forwards every MPV log message through a bare
/// `print`, and media_kit's native reference holder does the same in debug
/// builds. Two of those channels are pure noise for us: the `osc` property
/// probe (media_kit sets `osc` unconditionally; MPV builds without the
/// on-screen-controller reject it, and the error is emitted outside the
/// `msg-level` filter) and the `lavf` file-cache probe. Neither affects
/// playback — network streams keep working; only local file *caching* is
/// skipped. The NativeReferenceHolder allocations are debug-only bookkeeping.
const List<String> _mutedLogMarkers = <String>[
  'property not found _setProperty(osc',
  'Failed to create file cache',
  'media_kit: NativeReferenceHolder:',
];

bool _isMutedLog(Object? line) {
  final String text = '$line';
  return _mutedLogMarkers.any(text.contains);
}

Future<void> main() async {
  // runZoned guards runApp and every later print from the audio backend:
  // the zone stays current for callbacks scheduled from here onward.
  await runZoned<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks([
          'Lazer',
        ], await rootBundle.loadString('LICENSE'));
        yield LicenseEntryWithLineBreaks(
          ['Lyric animation'],
          await rootBundle.loadString('licenses/lyric_animation/AGPL-3.0.txt'),
        );
        yield const LicenseEntryWithLineBreaks(
          ['MiSans'],
          'This application uses MiSans by Xiaomi.\n'
          'MiSans Fonts Intellectual Property License Agreement:\n'
          'https://hyperos.mi.com/font/en/download/',
        );
      });
      JustAudioMediaKit.ensureInitialized();
      // Queue playback hands the next track to libmpv while the current one is
      // still playing, but mpv only opens that entry early with
      // `--prefetch-playlist`. Without it a streamed boundary waits for the
      // CDN round trip (measured: 171 ms of buffering at the switch with a
      // 150 ms server, versus 1 ms with the prefetch on) — an audible hole.
      JustAudioMediaKit.prefetchPlaylist = true;
      // Desktop replaces the system title bar with the app's own parchment
      // frame; must run before the first frame, which is also when the
      // runner decides to show the window.
      await initWindowFrame();
      final prefs = await SharedPreferences.getInstance();
      // The television input model (D-pad focus) needs this before the first
      // frame: a television with no pointer would otherwise boot into a screen
      // where nothing can be operated.
      final bool television = await detectTelevision();
      final audio = JustAudioEngine();
      final state = AppState(
        audioEngine: audio,
        enableExternalCharts: true,
        deviceIsTelevision: television,
        independentPlayback:
            prefs.getBool('lazer_independent_playback') ?? false,
      );
      final session = PlaybackSession(state, audio);
      final media = SystemMediaController(state);
      runApp(
        LazerApp(state: state, audio: audio, media: media, session: session),
      );
    },
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
        if (_isMutedLog(line)) return;
        parent.print(self, line);
      },
    ),
  );
}

/// Music player backed by the ported NetEase gateway.
class LazerApp extends StatefulWidget {
  const LazerApp({
    super.key,
    required this.state,
    required this.audio,
    required this.media,
    this.session,
  });
  final AppState state;
  final JustAudioEngine audio;
  final SystemMediaController media;
  final PlaybackSession? session;

  @override
  State<LazerApp> createState() => _LazerAppState();
}

class _LazerAppState extends State<LazerApp> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    // Only structural changes (sign-in/out) may rebuild from the root.
    // The 100 ms playback ticks are consumed by leaf transport widgets;
    // previously every tick rebuilt the whole app here, which — on
    // Windows with an accessibility client attached — fed a per-frame
    // AXTree sync storm and froze the UI.
    _state.addListener(_onSessionChanged);
    _state.bootstrap();
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _state.removeListener(_onSessionChanged);
    widget.media.close();
    widget.session?.close();
    _state.dispose();
    widget.audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The 配色 setting can seed the whole scheme from the current cover or a
    // colour the listener picked.
    final Color? seed = _state.legacyAccentSeed;
    return InteractionFeedback(
      state: _state,
      child: MaterialApp(
        title: 'Lazer · Field Player',
        debugShowCheckedModeBanner: false,
        // One Apple surface theme drives the custom window frame, root
        // dialogs and the adaptive shell. Pages refine their local player
        // theme where Apple Music intentionally switches to a dark canvas.
        theme: buildAppleTheme(brightness: Brightness.light, seedAccent: seed),
        darkTheme: buildAppleTheme(
          brightness: Brightness.dark,
          seedAccent: seed,
        ),
        themeMode: _state.themeMode,
        locale: _state.language.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        localeListResolutionCallback: (locales, _) =>
            AppLocalizations.resolveLocales(locales),
        scrollBehavior: AppScrollBehavior(
          retention: _state.scrollRetention,
          acceleration: _state.scrollAcceleration,
        ),
        // The whole interface — custom title bar included — is drawn at the
        // resolved DPI scale, so the window frame and the pages agree. The car
        // profile additionally rooms out the framework's own tap targets.
        // WindowFrame is a pass-through off desktop: the system frame (and the
        // plain MaterialApp) stays as it was there.
        builder: (context, child) => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            UiScaling(
              state: _state,
              child: CarMetrics(child: WindowFrame(child: child!)),
            ),
            if (_state.showFrameStats) const FrameStatsOverlay(),
          ],
        ),
        // Structural rebuilds only: `setState` fires on sign-in/out, never on
        // the 100 ms position ticks (leaf transport widgets consume those).
        // Keep exactly one root subtree during auth changes. AnimatedSwitcher
        // temporarily keeps both pages alive; with Windows UIA enabled that
        // overlap can leave AX nodes pending after the old page is detached.
        // The shell is always home: the guest session boots straight into
        // it, and sign-in happens in a popup card that closes over this —
        // no gate, no home swap to churn the accessibility tree.
        home: LegacyShell(
          key: const ValueKey('legacy'),
          state: _state,
          autoCheckUpdates: true,
        ),
      ),
    );
  }
}
