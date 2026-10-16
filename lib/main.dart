import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'l10n/app_localizations.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/services.dart' show rootBundle;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:audio_session/audio_session.dart';

import 'audio/audio_engine.dart';
import 'audio/system_media_handler.dart';
import 'screens/player_page.dart';
import 'state/app_state.dart';
import 'theme/app_theme.dart';
import 'widgets/window_frame.dart';
import 'widgets/interaction_feedback.dart';
import 'widgets/app_scroll_behavior.dart';

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
      // Desktop replaces the system title bar with the app's own parchment
      // frame; must run before the first frame, which is also when the
      // runner decides to show the window.
      await initWindowFrame();
      final audio = JustAudioEngine();
      final state = AppState(audioEngine: audio);
      final media = await initializeSystemMedia(state);
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      runApp(LazerApp(state: state, audio: audio, media: media));
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
  });
  final AppState state;
  final JustAudioEngine audio;
  final LazerMediaHandler media;

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
    _state.dispose();
    widget.audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // WindowFrame is a pass-through off desktop: the system frame (and the
    // plain MaterialApp) stays exactly as it was.
    return InteractionFeedback(
      state: _state,
      child: MaterialApp(
        title: 'Lazer · Field Player',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        darkTheme: buildAppTheme(brightness: Brightness.dark),
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
            AppLocalizations.resolve(locales?.firstOrNull),
        scrollBehavior: AppScrollBehavior(
          retention: _state.scrollRetention,
          acceleration: _state.scrollAcceleration,
        ),
        builder: (context, child) => WindowFrame(child: child!),
        // Structural rebuilds only: `setState` fires on sign-in/out, never on
        // the 100 ms position ticks (leaf transport widgets consume those).
        // Keep exactly one root subtree during auth changes. AnimatedSwitcher
        // temporarily keeps both pages alive; with Windows UIA enabled that
        // overlap can leave AX nodes pending after the old page is detached.
        // The shell is always home: the guest session boots straight into
        // it, and sign-in happens in a popup card that closes over this —
        // no gate, no home swap to churn the accessibility tree.
        home: PlayerPage(key: const ValueKey('player'), state: _state),
      ),
    );
  }
}
