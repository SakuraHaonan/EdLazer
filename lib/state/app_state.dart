import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/audio_engine.dart';
import '../interaction/app_haptics.dart';
import '../data/catalog.dart';
import '../data/lyrics.dart';
import '../scrolling/scroll_motion.dart';
import '../l10n/app_language.dart';
import '../data/models.dart';
import '../gateway/gateway.dart';
import '../gateway/transport.dart';
import 'ui_preferences.dart';

/// How the session was authenticated.
enum AuthMethod { qrcode, sms, password, cookie }

/// Immutable snapshot of the signed-in user.
class SessionUser {
  const SessionUser({
    required this.name,
    required this.handle,
    required this.method,
    required this.detail,
    this.userId = 0,
    this.avatarUrl,
    this.signature,
    this.vipType,
  });

  /// The default session: the app boots straight into the shell with this
  /// guest — no gate, no credentials. Signing in is optional, from the
  /// user card or the settings sheet.
  static const SessionUser guest = SessionUser(
    name: '游客',
    handle: '@guest',
    method: AuthMethod.cookie,
    detail: '未登录',
  );

  final String name;
  final String handle;
  final AuthMethod method;

  /// Human-readable credential detail, e.g. masked phone number.
  final String detail;
  final int userId;

  /// Profile avatar, when the gateway returned one.
  final String? avatarUrl;

  /// The user's profile signature ("个人简介").
  final String? signature;

  /// Raw NetEase VIP tier (0 = none).
  final int? vipType;

  bool get isGuest => handle == '@guest';

  /// Membership badge text for the profile header; null when not a VIP.
  String? get vipLabel {
    final int type = vipType ?? 0;
    if (isGuest || type <= 0) return null;
    return '黑胶会员';
  }

  String get methodLabel => isGuest
      ? '游客模式'
      : switch (method) {
          AuthMethod.qrcode => '二维码登录',
          AuthMethod.sms => '短信验证码登录',
          AuthMethod.password => '密码登录',
          AuthMethod.cookie => 'Cookie 登录',
        };

  factory SessionUser.fromProfile(
    GatewayUserProfile profile, {
    required AuthMethod method,
    required String detail,
  }) {
    return SessionUser(
      name: profile.nickname.isEmpty ? '乐迷' : profile.nickname,
      handle: '@${profile.userId}',
      method: method,
      detail: detail,
      userId: profile.userId,
      avatarUrl: profile.avatarUrl,
      signature: profile.signature,
      vipType: profile.vipType,
    );
  }
}

/// Outcome of a sign-in attempt; [error] is user-facing.
class AuthOutcome {
  const AuthOutcome(this.ok, {this.error});

  final bool ok;
  final String? error;
}

/// Single source of truth: session (real gateway) + playback engine.
///
/// Playback uses a real [AudioEngine] and stream URL from the gateway.
class AppState extends ChangeNotifier {
  AppState({
    Catalog? catalog,
    this.audioEngine,
    this._independentPlayback = false,
  }) : catalog = catalog ?? Catalog() {
    _completionSubscription = audioEngine?.completed.listen(
      (_) => _onEngineCompleted(),
    );
  }

  bool _independentPlayback;
  bool get independentPlayback => _independentPlayback;

  Future<void> setIndependentPlayback(bool value) async {
    if (_independentPlayback == value) return;
    _independentPlayback = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_independent_playback', _independentPlayback);
  }

  static const String _sessionKey = 'lazer_gateway_cookie';
  static const String _queueKey = 'lazer_playback_queue_v1';

  final Catalog catalog;
  StreamSubscription<void>? _completionSubscription;
  static const playbackInterval = Duration(milliseconds: 100);
  static const lyricFollowInterval = Duration(milliseconds: 5);
  bool hapticsEnabled = true;
  final AppHaptics haptics = AppHaptics();
  Future<void> feedback({bool detent = false, bool boundary = false}) =>
      haptics.pulse(
        enabled: hapticsEnabled,
        intensity: hapticIntensity,
        detent: detent,
        boundary: boundary,
      );
  double hapticIntensity = 0.5;
  ThemeMode themeMode = ThemeMode.system;
  double _volume = 1;
  double _unmutedVolume = 1;
  double get volume => _volume;

  Future<void> setVolume(double value) async {
    if (!value.isFinite) return;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    notifyListeners();
    await audioEngine?.setVolume(_volume);
    // Persist the latest value even when several drag updates are in flight.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_volume', _volume);
    await prefs.setDouble('lazer_unmuted_volume', _unmutedVolume);
  }

  /// Live volume change for a drag in progress: updates the engine and the
  /// in-memory value without notifying the whole shell or touching prefs.
  /// Callers persist once on release with [setVolume].
  void previewVolume(double value) {
    if (!value.isFinite) return;
    _volume = value.clamp(0, 1);
    if (_volume > 0) _unmutedVolume = _volume;
    unawaited(audioEngine?.setVolume(_volume) ?? Future<void>.value());
  }

  Future<void> toggleMute() => setVolume(_volume > 0 ? 0 : _unmutedVolume);

  Future<void> setHapticIntensity(double value) async {
    hapticIntensity = value.clamp(0, 1);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_haptic_intensity',
      hapticIntensity,
    );
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_theme_mode',
      value.name,
    );
  }

  AppLanguage language = AppLanguage.system;
  Future<void> setLanguage(AppLanguage value) async {
    language = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_language',
      value.code,
    );
  }

  // -- interface ------------------------------------------------------------

  /// Which presentation the shell forces; [AppUiMode.auto] follows the width.
  AppUiMode uiMode = AppUiMode.auto;

  /// Which device form the density is tuned for; [AppSurface.auto] recognises
  /// a car head unit from the platform.
  AppSurface surface = AppSurface.auto;

  /// Manual interface scale, used while [autoDpiScale] is off.
  double dpiScale = kDpiScaleDefault;

  /// Whether the interface scale is derived from the window instead of
  /// [dpiScale].
  bool autoDpiScale = true;

  Future<void> setUiMode(AppUiMode value) async {
    if (uiMode == value) return;
    uiMode = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_ui_mode',
      value.name,
    );
  }

  /// Legacy shell backdrop: the album-coloured flowing canvas, or off.
  LegacyBackgroundMode legacyBackground =
      LegacyBackgroundMode.nowPlayingDynamic;

  /// `内容不透明度` of the legacy shell — how much of the backdrop the content
  /// veil hides.
  double legacyUiAlpha = 0.7;

  Future<void> setLegacyBackground(LegacyBackgroundMode value) async {
    if (legacyBackground == value) return;
    legacyBackground = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_background',
      value.name,
    );
  }

  Future<void> setLegacyUiAlpha(double value) async {
    if (!value.isFinite) return;
    legacyUiAlpha = value.clamp(0.4, 1.0);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_legacy_ui_alpha',
      legacyUiAlpha,
    );
  }

  Future<void> setSurface(AppSurface value) async {
    if (surface == value) return;
    surface = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_surface',
      value.name,
    );
  }

  /// Pins a manual scale. Dragging the slider is an explicit choice, so it
  /// turns the automatic mode off; [setAutoDpiScale] can turn it back on.
  Future<void> setDpiScale(double value) async {
    final double next = normalizeDpiScale(value);
    if (dpiScale == next && !autoDpiScale) return;
    dpiScale = next;
    autoDpiScale = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_dpi_scale', next);
    await prefs.setBool('lazer_auto_dpi_scale', false);
  }

  Future<void> setAutoDpiScale(bool value) async {
    if (autoDpiScale == value) return;
    autoDpiScale = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_auto_dpi_scale',
      value,
    );
  }

  /// Back to the shipped behaviour: automatic scale, 100% manual fallback.
  Future<void> resetDpiScale() async {
    autoDpiScale = true;
    dpiScale = kDpiScaleDefault;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_auto_dpi_scale', true);
    await prefs.setDouble('lazer_dpi_scale', kDpiScaleDefault);
  }

  double lyricControlsSeconds = 1.5;
  bool lyricBlurEnabled = true;
  bool showFrameStats = const bool.fromEnvironment('LAZER_FRAME_STATS');
  double lyricFontSize = 22;
  int lyricFontWeight = 600;
  static int normalizeLyricWeight(int value) =>
      (value.clamp(400, 700) / 100).round() * 100;

  Future<void> setShowFrameStats(bool value) async {
    if (showFrameStats == value) return;
    showFrameStats = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_show_frame_stats',
      value,
    );
  }

  /// The legacy shell's accent palette: the fixed Lazer scheme, or one seeded
  /// from the current cover like the app's "follow the song" palette.
  LegacyPaletteMode legacyPalette = LegacyPaletteMode.fixed;

  /// The last artwork seed the legacy backdrop extracted; only used while
  /// [legacyPalette] is [LegacyPaletteMode.nowPlaying].
  Color? legacySeed;

  Future<void> setLegacyPalette(LegacyPaletteMode value) async {
    if (legacyPalette == value) return;
    legacyPalette = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      'lazer_legacy_palette',
      value.name,
    );
  }

  void setLegacySeed(Color? value) {
    if (legacySeed == value) return;
    legacySeed = value;
    // The fixed palette does not consume the seed; rebuilding the whole shell
    // for it on every track change was pure work.
    if (legacyPalette == LegacyPaletteMode.nowPlaying) notifyListeners();
  }

  Future<void> setLyricFontSize(double value) async {
    if (!value.isFinite) return;
    lyricFontSize = value.clamp(14, 40);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_lyric_font_size',
      lyricFontSize,
    );
  }

  Future<void> setLyricFontWeight(int value) async {
    lyricFontWeight = normalizeLyricWeight(value);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setInt(
      'lazer_lyric_font_weight',
      lyricFontWeight,
    );
  }

  double scrollRetention = ScrollMotion.defaultRetention;
  double scrollAcceleration = ScrollMotion.defaultAcceleration;

  Future<void> setScrollAcceleration(double value) async {
    if (!value.isFinite) return;
    scrollAcceleration = value.clamp(
      ScrollMotion.minAcceleration,
      ScrollMotion.maxAcceleration,
    );
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_scroll_acceleration',
      scrollAcceleration,
    );
  }

  double lyricResumeSeconds = 2;

  Future<void> setLyricBlurEnabled(bool value) async {
    lyricBlurEnabled = value;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setBool(
      'lazer_lyric_blur',
      value,
    );
  }

  Future<void> setScrollRetention(double value) async {
    scrollRetention = value.clamp(
      ScrollMotion.minRetention,
      ScrollMotion.maxRetention,
    );
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_scroll_retention',
      scrollRetention,
    );
  }

  Future<void> setLyricResumeSeconds(double value) async {
    lyricResumeSeconds = value.clamp(1, 10);
    notifyListeners();
    await (await SharedPreferences.getInstance()).setDouble(
      'lazer_lyric_resume_seconds',
      lyricResumeSeconds,
    );
  }

  Future<void> setHapticsEnabled(bool value) async {
    hapticsEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('lazer_haptics', value);
  }

  Future<void> setLyricControlsSeconds(double value) async {
    lyricControlsSeconds = value.clamp(1, 10);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('lazer_lyric_controls_seconds', lyricControlsSeconds);
  }

  /// Real playback engine (just_audio in the app).
  final AudioEngine? audioEngine;

  /// Live home feed once [bootstrap] loaded it.
  HomeFeed? get home => catalog.home;
  String? get homeError => catalog.homeError;
  String? playbackError;
  UserCollections collections = UserCollections.empty;
  bool collectionsLoading = false;
  String? collectionsError;
  int? _collectionsPendingUid;

  Future<void> refreshCollections({bool force = false}) async {
    final uid = user.userId;
    if (uid <= 0) {
      collections = UserCollections.empty;
      collectionsError = null;
      return;
    }
    if (_collectionsPendingUid == uid) return;
    _collectionsPendingUid = uid;
    collectionsLoading = true;
    collectionsError = null;
    notifyListeners();
    try {
      if (force) await catalog.invalidateCollections(uid);
      final loaded = await catalog.userCollections(uid);
      if (user.userId == uid) collections = loaded;
    } catch (_) {
      if (user.userId == uid) collectionsError = '歌单读取失败，请重试。';
    } finally {
      if (_collectionsPendingUid == uid) _collectionsPendingUid = null;
      if (user.userId == uid) {
        collectionsLoading = false;
        notifyListeners();
      }
    }
  }

  void clearPlaybackError() {
    playbackError = null;
    notifyListeners();
  }

  List<LyricLine> lyrics = const <LyricLine>[];
  String? lyricsError;
  bool lyricsLoading = false;
  bool lyricsPureMusic = false;
  String? _lyricsTrackId;
  int _lyricGeneration = 0;
  final Set<String> _metadataLoaded = <String>{};
  final Set<String> _metadataPending = <String>{};
  Set<int> _likedSongIds = <int>{};
  String? likeError;
  bool get currentLiked {
    final id = int.tryParse(current?.id ?? '');
    return id != null && _likedSongIds.contains(id);
  }

  /// Size of the loaded personal like list (0 while guest or not yet loaded).
  int get likedCount => _likedSongIds.length;

  /// Whether the gateway was reachable on the last interaction.
  bool get online => catalog.online;

  NeteaseGateway get gateway => catalog.gateway;

  // -- session --------------------------------------------------------------

  /// Never null: the guest session is the default, so there is no gate —
  /// the shell is always reachable and sign-in is an upgrade, not a toll.
  SessionUser _user = SessionUser.guest;
  SessionUser get user => _user;
  bool get isGuest => _user.isGuest;
  bool get signedIn => !_user.isGuest;

  /// Restores any persisted gateway session, then loads the home feed.
  Future<void> bootstrap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _independentPlayback =
          prefs.getBool('lazer_independent_playback') ?? _independentPlayback;
      hapticsEnabled = prefs.getBool('lazer_haptics') ?? true;
      hapticIntensity = (prefs.getDouble('lazer_haptic_intensity') ?? 0.5)
          .clamp(0, 1);
      themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == prefs.getString('lazer_theme_mode'),
        orElse: () => ThemeMode.system,
      );
      language = AppLanguage.parse(prefs.getString('lazer_language'));
      legacyBackground = LegacyBackgroundModeLabels.parse(
        prefs.getString('lazer_legacy_background'),
      );
      legacyUiAlpha = (prefs.getDouble('lazer_legacy_ui_alpha') ?? 0.7).clamp(
        0.4,
        1.0,
      );
      uiMode = AppUiModeLabels.parse(prefs.getString('lazer_ui_mode'));
      surface = AppSurfaceLabels.parse(prefs.getString('lazer_surface'));
      dpiScale = normalizeDpiScale(
        prefs.getDouble('lazer_dpi_scale') ?? kDpiScaleDefault,
      );
      autoDpiScale = prefs.getBool('lazer_auto_dpi_scale') ?? true;
      _volume = (prefs.getDouble('lazer_volume') ?? 1).clamp(0, 1);
      _unmutedVolume =
          (prefs.getDouble('lazer_unmuted_volume') ??
                  (_volume > 0 ? _volume : 1))
              .clamp(0.01, 1);
      lyricControlsSeconds =
          (prefs.getDouble('lazer_lyric_controls_seconds') ?? 1.5).clamp(1, 10);
      lyricBlurEnabled = prefs.getBool('lazer_lyric_blur') ?? true;
      showFrameStats =
          prefs.getBool('lazer_show_frame_stats') ?? showFrameStats;
      lyricFontSize = (prefs.getDouble('lazer_lyric_font_size') ?? 22).clamp(
        14,
        40,
      );
      lyricFontWeight = normalizeLyricWeight(
        prefs.getInt('lazer_lyric_font_weight') ?? 600,
      );
      legacyPalette = LegacyPaletteModeLabels.parse(
        prefs.getString('lazer_legacy_palette'),
      );
      scrollRetention =
          (prefs.getDouble('lazer_scroll_retention') ??
                  ScrollMotion.defaultRetention)
              .clamp(ScrollMotion.minRetention, ScrollMotion.maxRetention);
      scrollAcceleration =
          (prefs.getDouble('lazer_scroll_acceleration') ??
                  ScrollMotion.defaultAcceleration)
              .clamp(
                ScrollMotion.minAcceleration,
                ScrollMotion.maxAcceleration,
              );
      lyricResumeSeconds = (prefs.getDouble('lazer_lyric_resume_seconds') ?? 2)
          .clamp(1, 10);
    } catch (_) {}
    // Apply interaction preferences before session and catalogue requests.
    notifyListeners();
    await audioEngine?.setVolume(_volume);
    await _restoreQueue();
    unawaited(_loadCurrentArtwork());
    unawaited(ensureCurrentLyrics());
    await _restoreSession();
    await refreshHome();
  }

  Future<void> refreshHome({bool force = false}) async {
    if (force) {
      await catalog.invalidateHome(userId: signedIn ? _user.userId : null);
    }
    unawaited(refreshCollections());
    await catalog.loadHome(userId: _user.userId);
    notifyListeners();
  }

  Future<void> _restoreSession() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cookie = prefs.getString(_sessionKey);
      if (cookie == null || cookie.trim().isEmpty) return;
      gateway.sessionCookie = cookie;
      final GatewayLoginStatus status = await gateway.loginStatus();
      final GatewayUserProfile? profile = status.profile;
      if (status.signedIn && profile != null) {
        _user = SessionUser.fromProfile(
          profile,
          method: AuthMethod.cookie,
          detail: _cookieDetail(cookie),
        );
        notifyListeners();
        unawaited(_refreshLikedSongs());
      } else {
        gateway.clearSession();
        await prefs.remove(_sessionKey);
      }
    } catch (_) {
      // Tests (no plugin) and offline boots stay on the guest session.
    }
  }

  Future<AuthOutcome> signInWithCookie(String cookie) async {
    try {
      final GatewayLoginStatus status = await gateway.loginWithCookie(cookie);
      final GatewayUserProfile? profile = status.profile;
      if (!status.signedIn || profile == null) {
        return const AuthOutcome(false, error: '这个 Cookie 无效或已过期。');
      }
      _adoptSession(
        profile,
        AuthMethod.cookie,
        _cookieDetail(gateway.sessionCookie ?? cookie),
      );
      return const AuthOutcome(true);
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithPhonePassword(
    String phone,
    String password,
  ) async {
    try {
      final GatewayLoginResult result = await gateway.loginWithPhonePassword(
        phone,
        password,
      );
      return _adoptLoginResult(result, AuthMethod.password, _maskPhone(phone));
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> signInWithPhoneCaptcha(
    String phone,
    String captcha,
  ) async {
    try {
      final GatewayLoginResult result = await gateway.loginWithPhoneCaptcha(
        phone,
        captcha,
      );
      return _adoptLoginResult(result, AuthMethod.sms, _maskPhone(phone));
    } catch (error) {
      return _failure(error);
    }
  }

  Future<AuthOutcome> sendSmsCode(String phone) async {
    try {
      await gateway.sendCaptcha(phone);
      return const AuthOutcome(true);
    } catch (error) {
      return _failure(error);
    }
  }

  /// Starts a QR session and returns the scan URL, or null on failure.
  Future<String?> beginQrLogin() async {
    _qrConfirmed = false;
    qrPollError = null;
    try {
      final String key = await gateway.createQrKey();
      if (key.isEmpty) return null;
      final String url = await gateway.createQrCodeUrl(key);
      return url.isEmpty ? null : url;
    } catch (_) {
      return null;
    }
  }

  /// Set once a poll answered 803. The account endpoint can trail the key
  /// confirmation by a moment, so later polls re-check the account before
  /// asking the key again (the key itself is spent after a confirmation).
  bool _qrConfirmed = false;

  /// Last transport/gateway failure while polling the scan key, for the
  /// sign-in card. Cleared as soon as a poll answers again — a silent 801
  /// fallback used to hide server rejections completely.
  String? qrPollError;

  /// Polls a QR key: 800 expired, 801 waiting, 802 scanned, 803 confirmed,
  /// 8821 needs a security check on the phone.
  ///
  /// Only 803 means "this session is signed in": the scan URL was rejected by
  /// the phone when the poll never leaves 801, and a not-yet-ready account
  /// after 803 must not be mistaken for an expired key either.
  Future<int> pollQrLogin(String url) async {
    final Uri? uri = Uri.tryParse(url);
    final String? key = uri?.queryParameters['codekey'];
    if (key == null || key.isEmpty) return 800;
    try {
      if (_qrConfirmed && await _adoptQrSession()) return 803;
      final GatewayQrCheck check = await gateway.checkQrCode(key);
      qrPollError = null;
      if (check.code == 803) {
        _qrConfirmed = true;
        if (await _adoptQrSession()) return 803;
        // Confirmed, account still syncing: stay on the "scanned" state and
        // let the next poll retry the account instead of dropping the login.
        return 802;
      }
      if (check.code == 800 && _qrConfirmed) {
        // A confirmed key is spent: later polls answer "expired" even though
        // the login succeeded. Give the account one more chance first.
        if (await _adoptQrSession()) return 803;
      }
      return check.code;
    } catch (error) {
      qrPollError = _friendly(error);
      return 801;
    }
  }

  /// Reads the account behind the confirmed QR cookie, retrying briefly:
  /// `MUSIC_U` is already installed by [pollQrLogin], but `/login/status`
  /// can answer "not signed in" for a beat after the confirmation.
  Future<bool> _adoptQrSession() async {
    for (int attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      try {
        final GatewayLoginStatus status = await gateway.loginStatus();
        final GatewayUserProfile? profile = status.profile;
        if (status.signedIn && profile != null) {
          _qrConfirmed = false;
          _adoptSession(profile, AuthMethod.qrcode, '扫码登录');
          return true;
        }
      } catch (_) {
        // Keep retrying — the account endpoint lags the confirmation.
      }
    }
    return false;
  }

  AuthOutcome _adoptLoginResult(
    GatewayLoginResult result,
    AuthMethod method,
    String detail,
  ) {
    final GatewayUserProfile? profile = result.profile;
    if (!result.ok || profile == null) {
      final String message = result.message ?? '';
      return AuthOutcome(
        false,
        error: message.isEmpty ? '登录失败，请稍后再试。' : message,
      );
    }
    _adoptSession(profile, method, detail);
    return const AuthOutcome(true);
  }

  void _adoptSession(
    GatewayUserProfile profile,
    AuthMethod method,
    String detail,
  ) {
    if (_user.userId != profile.userId) {
      collections = UserCollections.empty;
      _likedSongIds = <int>{};
    }
    _user = SessionUser.fromProfile(profile, method: method, detail: detail);
    _persistSession(gateway.sessionCookie);
    unawaited(refreshHome());
    unawaited(_refreshLikedSongs());
    notifyListeners();
  }

  /// Back to the guest session — stay in the shell, drop the credentials.
  void signOut() {
    collections = UserCollections.empty;
    collectionsLoading = false;
    collectionsError = null;
    pause();
    _queue = <Track>[];
    _queueIndex = 0;
    _position = Duration.zero;
    lyrics = const <LyricLine>[];
    ++_lyricGeneration;
    _lyricsTrackId = null;
    lyricsLoading = false;
    lyricsPureMusic = false;
    lyricsError = null;
    ++_generation;
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    unawaited(_saveQueue());
    _user = SessionUser.guest;
    _likedSongIds = <int>{};
    likeError = null;
    _qrConfirmed = false;
    gateway.clearSession();
    unawaited(_forgetSession());
    unawaited(refreshHome());
    notifyListeners();
  }

  Future<void> _persistSession(String? cookie) async {
    if (cookie == null || cookie.trim().isEmpty) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, cookie);
    } catch (_) {}
  }

  Future<void> _forgetSession() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } catch (_) {}
  }

  // -- catalogue actions ----------------------------------------------------

  Future<SearchResults> search(String query) => catalog.search(query);

  /// The signed-in user's collections for the "我" page. Errors propagate.
  Future<UserCollections> userCollections() =>
      catalog.userCollections(_user.userId);

  Future<void> playPlaylist(String playlistId) async {
    final List<Track> tracks = await catalog.playlistTracks(playlistId);
    playQueue(tracks);
  }

  Future<void> playAlbum(String albumId) async {
    final int id = int.tryParse(albumId) ?? 0;
    final List<Track> tracks = await catalog.albumTracks(id);
    playQueue(tracks);
  }

  // -- transport ------------------------------------------------------------
  //
  // Two notification lanes. `notifyListeners()` fires only on structural
  // changes (session, queue, play state); the 100 ms position ticks go
  // through the private [ticks] lane so leaf transport widgets update
  // without rebuilding whole screens. This keeps the semantics tree stable
  // while playing — the churn behind the Windows UIA log storm and the
  // perceived freezes.

  final _TickNotifier _tickNotifier = _TickNotifier();

  /// Position/progress updates only (fires every 100 ms while playing).
  Listenable get ticks => _tickNotifier;

  /// Structural changes AND ticks — for the transport widgets that mirror
  /// both (the dark player bar, the Now Playing transport).
  late final Listenable all = Listenable.merge(<Listenable>[
    this,
    _tickNotifier,
  ]);

  Timer? _ticker;
  List<Track> _queue = <Track>[];
  int _queueIndex = 0;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _shuffle = false;
  LoopMode _repeat = LoopMode.off;
  bool _realActive = false;
  int _generation = 0;
  int trackChangeDirection = 1;

  List<Track> get queue => List<Track>.unmodifiable(_queue);
  Track? get current =>
      _queue.isEmpty ? null : _queue[_queueIndex.clamp(0, _queue.length - 1)];
  Duration get position => _position;
  Duration get precisePosition => _realActive && audioEngine?.active == true
      ? audioEngine!.position
      : _position;
  bool get playing => _playing;
  bool get audioReady => _realActive && (audioEngine?.active ?? false);
  int get queueIndex => _queueIndex;
  bool get shuffle => _shuffle;
  LoopMode get repeat => _repeat;

  /// Whether the lyric request for the current track has finished (or failed).
  ///
  /// The now-playing page uses this instead of [lyricsLoading] alone so an
  /// empty list before the request starts cannot open the artwork by mistake.
  bool get currentLyricsSettled =>
      current != null && _lyricsTrackId == current!.id && !lyricsLoading;

  double get progress {
    final Track? t = current;
    if (t == null || t.duration.inMilliseconds == 0) return 0;
    return (_position.inMilliseconds / t.duration.inMilliseconds).clamp(0, 1);
  }

  /// How much of the current track the engine has buffered, 0…1.
  ///
  /// The now-playing seek rail paints this behind the played fraction. The
  /// plain [AudioEngine] contract carries no buffer information, so engines
  /// without [BufferedAudioEngine] fall back to the playhead.
  double get bufferedFraction {
    final Track? t = current;
    final int duration = t?.duration.inMilliseconds ?? 0;
    if (duration <= 0) return 0;
    final AudioEngine? engine = audioEngine;
    final Duration buffered = engine is BufferedAudioEngine
        ? (engine as BufferedAudioEngine).bufferedPosition
        : _position;
    return (buffered.inMilliseconds / duration).clamp(0.0, 1.0);
  }

  void playQueue(List<Track> tracks, {int startIndex = 0}) {
    if (tracks.isEmpty) return;
    trackChangeDirection = 1;
    _queue = List<Track>.of(tracks);
    _queueIndex = startIndex.clamp(0, tracks.length - 1);
    unawaited(_saveQueue());
    _position = Duration.zero;
    playbackError = null;
    unawaited(_loadLyrics());
    _ensureTicker();
    _playing = true;
    unawaited(_startAudio());
    notifyListeners();
  }

  void togglePlay() {
    if (current == null) return;
    _playing = !_playing;
    if (_playing) {
      if (_realActive) {
        unawaited(_resumeAudio());
      } else {
        playbackError = null;
        unawaited(_startAudio());
        _ensureTicker();
      }
    } else {
      _ticker?.cancel();
      if (_realActive) unawaited(audioEngine!.pause());
    }
    notifyListeners();
  }

  void play() {
    if (current == null || _playing) return;
    _playing = true;
    if (_realActive) {
      unawaited(_resumeAudio());
    } else {
      playbackError = null;
      unawaited(_startAudio());
      _ensureTicker();
    }
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _ticker?.cancel();
    if (_realActive) unawaited(audioEngine!.pause());
    notifyListeners();
  }

  void stop() {
    ++_generation;
    _playing = false;
    _realActive = false;
    _position = Duration.zero;
    playbackError = null;
    _ticker?.cancel();
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    notifyListeners();
  }

  void next() {
    if (_queue.isEmpty) return;
    trackChangeDirection = 1;
    playbackError = null;
    _queueIndex = _shuffle
        ? (_queue.length == 1
              ? 0
              : (_randomIndex(_queue.length, avoid: _queueIndex)))
        : (_queueIndex + 1) % _queue.length;
    unawaited(_saveQueue());
    _position = Duration.zero;
    unawaited(_loadLyrics());
    if (_playing) {
      unawaited(_startAudio());
      _ensureTicker();
    }
    notifyListeners();
  }

  void previous() {
    if (_queue.isEmpty) return;
    playbackError = null;
    // Classic transport behavior: >3s in, "previous" restarts the track.
    if (_position.inSeconds > 3) {
      _position = Duration.zero;
      if (_realActive) unawaited(audioEngine!.seek(Duration.zero));
    } else {
      trackChangeDirection = -1;
      _queueIndex = (_queueIndex - 1 + _queue.length) % _queue.length;
      unawaited(_saveQueue());
      _position = Duration.zero;
      unawaited(_loadLyrics());
      if (_playing) unawaited(_startAudio());
    }
    notifyListeners();
    if (_playing) _ensureTicker();
  }

  void seek(double fraction) {
    final Track? t = current;
    if (t == null) return;
    final Duration target = t.duration * fraction.clamp(0, 1);
    _position = target;
    if (_realActive) unawaited(audioEngine!.seek(target));
    // Position-only change: tick lane, not a structural rebuild.
    _tickNotifier.pulse();
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    notifyListeners();
  }

  /// The legacy single play-mode button: Sequential → ListLoop → SingleLoop →
  /// Shuffle → Sequential.
  void cyclePlayMode() {
    if (_shuffle) {
      _shuffle = false;
      _repeat = LoopMode.off;
    } else if (_repeat == LoopMode.off) {
      _repeat = LoopMode.all;
    } else if (_repeat == LoopMode.all) {
      _repeat = LoopMode.one;
    } else {
      _repeat = LoopMode.off;
      _shuffle = true;
    }
    notifyListeners();
  }

  void cycleRepeat() {
    _repeat = switch (_repeat) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    notifyListeners();
  }

  void playTrackAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    trackChangeDirection = index < _queueIndex ? -1 : 1;
    playbackError = null;
    _queueIndex = index;
    unawaited(_saveQueue());
    _position = Duration.zero;
    unawaited(_loadLyrics());
    _playing = true;
    unawaited(_startAudio());
    _ensureTicker();
    notifyListeners();
  }

  /// Loads the stream URL. A locked or unavailable song stops playback and
  /// exposes a visible error instead of advancing a simulated clock.
  Future<void> _startAudio() async {
    unawaited(_loadCurrentArtwork());
    final AudioEngine? engine = audioEngine;
    final Track? track = current;
    if (track == null) return;
    final int generation = ++_generation;
    _realActive = false;
    String? url;
    try {
      url = await catalog.audioUrlFor(track);
    } catch (error) {
      if (generation == _generation) _failPlayback(_friendly(error));
      return;
    }
    if (generation != _generation) return;
    if (url == null || url.isEmpty) {
      _failPlayback('这首歌暂时无法播放，请换一首。');
      return;
    }
    if (engine == null) {
      _failPlayback('当前设备没有可用的音频播放器。');
      return;
    }
    try {
      await engine.setUrl(url);
      if (generation != _generation) return;
      await engine.setVolume(_volume);
    } catch (error) {
      if (generation == _generation) _failPlayback('音频加载失败，请重试。');
      return;
    }
    if (generation != _generation) return;
    _realActive = true;
    if (_playing) unawaited(_resumeAudio());
    notifyListeners();
  }

  Future<void> _loadCurrentArtwork() async {
    final track = current;
    if (track == null ||
        _metadataLoaded.contains(track.id) ||
        _metadataPending.contains(track.id)) {
      return;
    }
    final id = int.tryParse(track.id);
    if (id == null || id <= 0) return;
    _metadataPending.add(track.id);
    try {
      final songs = await gateway.songDetails(<int>[id]);
      final song = songs.where((song) => song.id == id).firstOrNull;
      if (song == null) return;
      _metadataLoaded.add(track.id);
      // Hydrate matching entries without replacing the current queue or
      // erasing artwork and translations when a field is absent upstream.
      bool changed = false;
      _queue = _queue.map((entry) {
        if (entry.id != track.id ||
            (entry.coverUrl == song.coverUrl &&
                entry.translatedTitle == song.translatedTitle &&
                entry.albumId > 0 &&
                entry.artists.isNotEmpty)) {
          return entry;
        }
        changed = true;
        return Track(
          id: entry.id,
          title: entry.title,
          artist: entry.artist,
          artists: song.artistDetails.isNotEmpty
              ? song.artistDetails.map(Catalog.artistFromGateway).toList()
              : entry.artists,
          album: entry.album,
          duration: entry.duration,
          coverSeed: entry.coverSeed,
          accent: entry.accent,
          albumId: song.albumId > 0 ? song.albumId : entry.albumId,
          coverUrl: song.coverUrl ?? entry.coverUrl,
          translatedTitle: song.translatedTitle ?? entry.translatedTitle,
        );
      }).toList();
      if (changed) {
        unawaited(_saveQueue());
        notifyListeners();
      }
    } catch (_) {
      // Keep playback available; the next playback attempt can retry metadata.
    } finally {
      _metadataPending.remove(track.id);
    }
  }

  Future<void> _restoreQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_queueKey);
      if (raw == null) return;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json['tracks'] is! List) return;
      final tracks = <Track>[];
      for (final item in json['tracks'] as List) {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id'] as String? ?? '';
        if (int.tryParse(id) == null) continue;
        tracks.add(
          Track(
            id: id,
            title: item['title'] as String? ?? '',
            artist: item['artist'] as String? ?? '',
            artists: ArtistRef.list(item['artists']),
            album: item['album'] as String? ?? '',
            duration: Duration(
              milliseconds: (item['durationMs'] as num?)?.toInt() ?? 0,
            ),
            coverSeed: (item['coverSeed'] as num?)?.toInt() ?? 0,
            accent: (item['accent'] as num?)?.toInt() ?? 0,
            albumId: (item['albumId'] as num?)?.toInt() ?? 0,
            coverUrl: item['coverUrl'] as String?,
            translatedTitle: item['translatedTitle'] as String?,
          ),
        );
      }
      _queue = tracks;
      _queueIndex = ((json['index'] as num?)?.toInt() ?? 0).clamp(
        0,
        tracks.isEmpty ? 0 : tracks.length - 1,
      );
      notifyListeners();
    } catch (_) {
      // Corrupt or inaccessible local state leaves an empty queue.
    }
  }

  Future<void> _saveQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _queueKey,
        jsonEncode(<String, Object?>{
          'index': _queueIndex,
          'tracks': <Map<String, Object?>>[
            for (final track in _queue)
              <String, Object?>{
                'id': track.id,
                'title': track.title,
                'translatedTitle': track.translatedTitle,
                'artist': track.artist,
                'artists': track.artists
                    .map((artist) => artist.toJson())
                    .toList(),
                'album': track.album,
                'albumId': track.albumId,
                'durationMs': track.duration.inMilliseconds,
                'coverSeed': track.coverSeed,
                'accent': track.accent,
                'coverUrl': track.coverUrl,
              },
          ],
        }),
      );
    } catch (_) {}
  }

  Future<void> _resumeAudio() async {
    final generation = _generation;
    try {
      await audioEngine!.play();
    } catch (_) {
      if (generation == _generation) _failPlayback('播放中断，请重试。');
    }
  }

  Future<void> _refreshLikedSongs() async {
    final uid = _user.userId;
    if (uid <= 0) return;
    try {
      final ids = await gateway.likedSongIds(uid);
      if (_user.userId != uid) return;
      _likedSongIds = ids;
      notifyListeners();
    } catch (_) {
      // Personal likes are optional while public playback remains available.
    }
  }

  Future<void> toggleLikeCurrent() async {
    final id = int.tryParse(current?.id ?? '');
    final uid = _user.userId;
    if (id == null || uid <= 0) return;
    final liked = !_likedSongIds.contains(id);
    likeError = null;
    try {
      await gateway.setSongLiked(id, uid, liked);
      if (_user.userId != uid) return;
      if (liked) {
        _likedSongIds.add(id);
      } else {
        _likedSongIds.remove(id);
      }
      // The next entry into the liked playlist must reflect this mutation.
      final playlistId = collections.liked?.id;
      if (playlistId != null) await catalog.invalidatePlaylist(playlistId);
      await catalog.invalidateCollections(_user.userId);
    } catch (_) {
      likeError = '收藏失败，请稍后重试。';
    }
    notifyListeners();
  }

  Future<void> ensureCurrentLyrics({bool force = false}) async {
    final track = current;
    if (track == null) return;
    if (force) {
      await catalog.invalidateLyrics(track.id);
      if (current?.id != track.id) return;
    }
    if (!force &&
        _lyricsTrackId == track.id &&
        (lyricsLoading || lyrics.isNotEmpty || lyricsPureMusic)) {
      return;
    }
    await _loadLyrics();
  }

  Future<void> _loadLyrics() async {
    final track = current;
    final generation = ++_lyricGeneration;
    lyrics = const <LyricLine>[];
    lyricsError = null;
    _lyricsTrackId = track?.id;
    lyricsLoading = track != null;
    lyricsPureMusic = false;
    notifyListeners();
    if (track == null) return;
    try {
      final payload = await catalog.lyricsFor(track);
      if (generation != _lyricGeneration) return;
      lyrics = payload == null ? const <LyricLine>[] : parseLyrics(payload);
      lyricsPureMusic = payload?.pureMusic ?? false;
    } catch (_) {
      if (generation != _lyricGeneration) return;
      lyricsError = '歌词暂时无法加载。';
    }
    lyricsLoading = false;
    notifyListeners();
  }

  void _failPlayback(String message) {
    _realActive = false;
    _playing = false;
    _ticker?.cancel();
    playbackError = message;
    unawaited(audioEngine?.stop() ?? Future<void>.value());
    notifyListeners();
  }

  void _onEngineCompleted() {
    if (!_realActive || !_playing) return;
    // Consume the terminal state before seeking/loading; some backends emit
    // both a completed event and a final position update for the same source.
    _realActive = false;
    final AudioEngine engine = audioEngine!;
    if (_repeat == LoopMode.one) {
      _position = Duration.zero;
      final generation = _generation;
      unawaited(() async {
        try {
          await engine.seek(Duration.zero);
          if (generation != _generation || !_playing) return;
          _realActive = true;
          unawaited(_resumeAudio());
        } catch (_) {
          if (generation == _generation) _failPlayback('播放中断，请重试。');
        }
      }());
      _tickNotifier.pulse();
      return;
    }
    if (_repeat == LoopMode.all ||
        _shuffle && _queue.length > 1 ||
        _queueIndex < _queue.length - 1) {
      next();
      return;
    }
    _position = current?.duration ?? Duration.zero;
    _playing = false;
    _realActive = false;
    _ticker?.cancel();
    engine.stop();
    notifyListeners();
  }

  void _ensureTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(playbackInterval, (_) => _tick());
  }

  void _tick() {
    final Track? t = current;
    if (t == null || !_playing) return;
    if (_realActive) {
      _position = audioEngine!.position;
      // A native duration/position is a second completion signal for backends
      // that omit the terminal processing-state event. Never use metadata or
      // an estimated clock here: unavailable/buffering songs must not advance.
      final duration = audioEngine!.duration;
      if (duration != null &&
          duration > Duration.zero &&
          _position >= duration) {
        _onEngineCompleted();
        return;
      }
      _tickNotifier.pulse();
      return;
    }
    // The URL is still loading. Do not invent elapsed time.
  }

  final int _seedState = DateTime.now().millisecondsSinceEpoch;

  int _randomIndex(int n, {int? avoid}) {
    // Select a different queue index when shuffle is active.
    int r = (_seedState + n * 31 + (_avoidCounter++)) % n;
    if (avoid != null && r == avoid && n > 1) r = (r + 1) % n;
    return r;
  }

  int _avoidCounter = 0;

  static AuthOutcome _failure(Object error) =>
      AuthOutcome(false, error: _friendly(error));

  static String _maskPhone(String phone) {
    final String trimmed = phone.trim();
    if (trimmed.length <= 4) return trimmed;
    return '${trimmed.substring(0, 3)}****${trimmed.substring(trimmed.length - 4)}';
  }

  static String _cookieDetail(String cookie) {
    final int fields = cookie
        .split(';')
        .where((String s) => s.trim().isNotEmpty)
        .length;
    return '$fields 个字段';
  }

  static String _friendly(Object error) {
    if (error is GatewayHttpException) {
      return '网络请求失败（HTTP ${error.statusCode}）。';
    }
    if (error is GatewayProtocolException) return '服务返回了无法解析的数据。';
    if (error is GatewayServiceException) return '服务暂时拒绝了请求（${error.code}）。';
    if (error is ArgumentError) return error.message?.toString() ?? '输入无效。';
    return '连接失败，请检查网络后重试。';
  }

  @override
  void dispose() {
    ++_generation;
    ++_lyricGeneration;
    _completionSubscription?.cancel();
    _ticker?.cancel();
    _tickNotifier.dispose();
    super.dispose();
  }
}

enum LoopMode { off, all, one }

/// Tick-only heartbeat lane. `notifyListeners()` is @protected, so this thin
/// subclass exposes [pulse] for the 100 ms position updates that must not
/// rebuild whole screens (see AppState's transport note).
class _TickNotifier extends ChangeNotifier {
  void pulse() => notifyListeners();
}

/// Format mm:ss.
String fmt(Duration d) {
  final int m = d.inMinutes;
  final int s = d.inSeconds % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
}
