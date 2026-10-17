import 'package:lazer_nextgen/theme/app_palette.dart';
import '../l10n/app_localizations.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';
import '../theme/design_tokens.dart';
import '../theme/paper_widgets.dart';

/// Which credential flow the login card is showing.
enum LoginMode { qrcode, sms, password, cookie }

extension on LoginMode {
  String get label => switch (this) {
    LoginMode.qrcode => '二维码',
    LoginMode.sms => '验证码',
    LoginMode.password => '密码',
    LoginMode.cookie => 'Cookie',
  };
}

/// Opens sign-in as a small popup card over the shell — the guest session
/// is already running underneath, so this is an upgrade, never a gate.
Future<void> showLoginDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext context) => Dialog(
      backgroundColor: context.colors.ivoryLight,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      clipBehavior: Clip.antiAlias,
      // Paper frame: square, hairline, flat — elevation by tone + border.
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: context.borders.hairline,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: LoginPage(state: state),
      ),
    ),
  );
}

/// The sign-in card shown inside [showLoginDialog]: a compact editorial
/// panel with the four credential flows; the clay accent appears only on
/// the final "登录" action.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.state});

  final AppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  LoginMode _mode = LoginMode.qrcode;

  void _close() => Navigator.of(context).maybePop();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header: wordmark left, dismiss right — a card, not a gate.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Text('LAZER', style: context.type.wordmark),
                    const SizedBox(width: 10),
                    InlineLabel(
                      'FIELD PLAYER',
                      color: context.colors.cloudDark,
                    ),
                  ],
                ),
                TextLinkButton(label: '取消', onPressed: _close),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            // Editorial serif headline + supporting line.
            TrText(
              '登录你的曲库',
              textAlign: TextAlign.center,
              style: context.type.subheading.copyWith(fontSize: 26),
            ),
            const SizedBox(height: AppSpacing.sm),
            TrText(
              '登录后同步你的歌单和每日推荐。',
              textAlign: TextAlign.center,
              style: context.type.body.copyWith(
                fontSize: 15,
                height: 1.55,
                color: context.colors.cloudDark,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),

            PaperCard(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ModeTabs(
                    current: _mode,
                    onChanged: (LoginMode m) => setState(() => _mode = m),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Hairline(),
                  const SizedBox(height: AppSpacing.md),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOut,
                    alignment: Alignment.topCenter,
                    child: switch (_mode) {
                      LoginMode.qrcode => QrPanel(
                        key: const ValueKey('qr'),
                        state: widget.state,
                      ),
                      LoginMode.sms => SmsPanel(
                        key: const ValueKey('sms'),
                        state: widget.state,
                      ),
                      LoginMode.password => PasswordPanel(
                        key: const ValueKey('pwd'),
                        state: widget.state,
                      ),
                      LoginMode.cookie => CookiePanel(
                        key: const ValueKey('cookie'),
                        state: widget.state,
                      ),
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TrText(
              '使用网易云音乐账户登录',
              textAlign: TextAlign.center,
              style: context.type.captionMuted.copyWith(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

/// The four credential flows as editorial text tabs — persistent underline
/// marks the selection (print convention), no containers, no pills.
class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.current, required this.onChanged});

  final LoginMode current;
  final ValueChanged<LoginMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: LoginMode.values.map((LoginMode m) {
        final bool active = m == current;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(m),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Column(
                children: [
                  TrText(
                    m.label,
                    style: context.type.bodySm.copyWith(
                      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                      color: active
                          ? context.colors.slateDark
                          : context.colors.cloudMedium,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 1,
                    width: 44,
                    color: active
                        ? context.colors.slateDark
                        : Colors.transparent,
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared field chrome — hairline outline, 12px radius, focus darkens to
// slate. No clay on chrome; the accent stays on CTAs only.
// ---------------------------------------------------------------------------

class PaperField extends StatefulWidget {
  const PaperField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.errorText,
    this.obscure = false,
    this.keyboardType,
    this.maxLines = 1,
    this.maxLength,
    this.prefix,
    this.inputFormatters,
    this.onSubmitted,
    this.mono = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final String? errorText;
  final bool obscure;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? maxLength;
  final Widget? prefix;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onSubmitted;
  final bool mono;

  @override
  State<PaperField> createState() => _PaperFieldState();
}

class _PaperFieldState extends State<PaperField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool hasError = widget.errorText != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InlineLabel(widget.label),
        const SizedBox(height: 6),
        Focus(
          onFocusChange: (bool f) => setState(() => _focused = f),
          child: Container(
            constraints: BoxConstraints(
              minHeight: widget.maxLines == 1 ? 52 : 120,
            ),
            decoration: BoxDecoration(
              color: context.colors.ivoryLight,
              borderRadius: BorderRadius.zero,
              border: Border.all(
                color: hasError
                    ? context.colors.clayDeep
                    : _focused
                    ? context.colors.slateDark
                    : context.colors.stone,
                width: 1,
              ),
            ),
            padding: EdgeInsets.symmetric(
              horizontal: 14,
              vertical: widget.maxLines > 1 ? 8 : 0,
            ),
            child: Row(
              crossAxisAlignment: widget.maxLines > 1
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.center,
              children: [
                if (widget.prefix != null) ...[
                  widget.prefix!,
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: TextField(
                    controller: widget.controller,
                    obscureText: widget.obscure,
                    keyboardType: widget.keyboardType,
                    maxLines: widget.obscure ? 1 : widget.maxLines,
                    maxLength: widget.maxLength,
                    inputFormatters: widget.inputFormatters,
                    onSubmitted: widget.onSubmitted,
                    style: widget.mono
                        ? context.type.mono.copyWith(fontSize: 13, height: 1.5)
                        : context.type.bodySm.copyWith(fontSize: 15),
                    decoration: InputDecoration(
                      isDense: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                      border: InputBorder.none,
                      counterText: '',
                      hintText: widget.hint == null
                          ? null
                          : context.tr(widget.hint!),
                      hintStyle: context.type.bodySm.copyWith(
                        fontSize: 15,
                        color: context.colors.cloudMedium,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasError) ...[
          const SizedBox(height: 6),
          TrText(
            widget.errorText!,
            style: context.type.caption.copyWith(
              color: context.colors.clayDeep,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );
  }
}

/// Phone input with a +86 prefix and 11-digit formatting.
class PhoneField extends StatelessWidget {
  const PhoneField({
    super.key,
    required this.controller,
    required this.errorText,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? errorText;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return PaperField(
      controller: controller,
      label: '手机号',
      hint: '11 位手机号码',
      errorText: errorText,
      keyboardType: TextInputType.phone,
      maxLength: 13, // "138 1234 5678" formatted
      onSubmitted: onSubmitted,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(11),
        _PhoneGroupFormatter(),
      ],
      prefix: Row(
        children: [
          Text(
            '+86',
            style: context.type.bodySm.copyWith(
              fontSize: 15,
              color: context.colors.cloudDark,
            ),
          ),
          const SizedBox(width: 8),
          const Hairline(vertical: true, length: 18),
        ],
      ),
    );
  }
}

/// Groups digits as 3-4-4, mainland style.
class _PhoneGroupFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String digits = newValue.text.replaceAll(' ', '');
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i == 3 || i == 7) sb.write(' ');
      sb.write(digits[i]);
    }
    final String formatted = sb.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String digitsOf(String raw) => raw.replaceAll(RegExp(r'\D'), '');

bool isValidPhone(String raw) =>
    RegExp(r'^1[3-9]\d{9}$').hasMatch(digitsOf(raw));

/// Shared busy state for gateway authentication.
mixin SignInFlow<T extends StatefulWidget> on State<T> {
  bool _busy = false;
  bool get busy => _busy;

  void setBusy(bool value) {
    if (!mounted) return;
    setState(() => _busy = value);
  }

  Future<void> runSignIn(
    Future<AuthOutcome> action, {
    required ValueChanged<String> onError,
  }) async {
    setBusy(true);
    final AuthOutcome outcome = await action;
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).maybePop();
      return;
    }
    setBusy(false);
    onError(outcome.error ?? '登录失败，请稍后再试。');
  }
}

/// A small busy row shown while the request is in flight.
class BusyRow extends StatelessWidget {
  const BusyRow({super.key, required this.busy, required this.child});

  final bool busy;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!busy) return child;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        TrText('正在登录…', style: context.type.bodySmMuted),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 1 · QR code
// ---------------------------------------------------------------------------

enum _QrPhase { fresh, scanned, expired }

/// How long a scan URL stays valid. The service expires the unikey itself
/// (the poll then answers 800); this local bound only stops a dead QR from
/// staying on screen forever.
const int _qrLifetimeSeconds = 180;

/// A poll every two seconds is what the reference implementation expects;
/// the first one runs immediately so a scan during the key handshake is not
/// missed for a whole tick.
const Duration _qrPollInterval = Duration(seconds: 2);

class QrPanel extends StatefulWidget {
  const QrPanel({super.key, required this.state});

  final AppState state;

  @override
  State<QrPanel> createState() => _QrPanelState();
}

class _QrPanelState extends State<QrPanel> with SignInFlow<QrPanel> {
  _QrPhase _phase = _QrPhase.fresh;
  int _secondsLeft = _qrLifetimeSeconds;
  Timer? _timer;

  /// Scan URL issued by the gateway.
  String? _qrUrl;
  String? _qrError;
  Timer? _poll;

  /// Guards against overlapping polls: a slow request must not let the next
  /// tick race it and replay an older session cookie.
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_beginReal());
  }

  Future<void> _beginReal() async {
    final String? url = await widget.state.beginQrLogin();
    if (!mounted) return;
    setState(() {
      _qrUrl = url;
      _qrError = url == null ? '二维码获取失败，请检查网络后重试。' : null;
    });
    if (url != null) _startPolling();
    if (url != null) _startCountdown();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(_qrPollInterval, (Timer _) {
      unawaited(_pollOnce());
    });
    // Don't make the first poll wait a full interval.
    unawaited(_pollOnce());
  }

  Future<void> _pollOnce() async {
    final String? url = _qrUrl;
    if (_polling || !mounted || url == null || _phase == _QrPhase.expired) {
      return;
    }
    _polling = true;
    try {
      final int code = await widget.state.pollQrLogin(url);
      if (!mounted || _phase == _QrPhase.expired) return;
      switch (code) {
        case 803:
          _poll?.cancel();
          _timer?.cancel();
          Navigator.of(context).maybePop();
        case 802:
          if (_phase != _QrPhase.scanned) {
            setState(() => _phase = _QrPhase.scanned);
          }
        case 800:
          _poll?.cancel();
          setState(() => _phase = _QrPhase.expired);
        default:
          // 801 (waiting to be scanned) and transient network errors keep the
          // QR alive; the poll just tries again on the next tick.
          break;
      }
    } finally {
      _polling = false;
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted || _phase == _QrPhase.expired) {
        t.cancel();
        return;
      }
      final int next = _secondsLeft - 1;
      if (next <= 0) {
        t.cancel();
        _poll?.cancel();
        setState(() => _phase = _QrPhase.expired);
        return;
      }
      setState(() => _secondsLeft = next);
    });
  }

  void _refresh() {
    _poll?.cancel();
    setState(() {
      _phase = _QrPhase.fresh;
      _secondsLeft = _qrLifetimeSeconds;
      _qrUrl = null;
      _qrError = null;
      _polling = false;
    });
    unawaited(_beginReal());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String? url = _qrUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: SizedBox(
            width: 208,
            height: 208,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PaperCard(
                  padding: const EdgeInsets.all(14),
                  background: context.colors.ivoryLight,
                  child: url != null
                      ? QrImageView(
                          data: url,
                          size: 178,
                          backgroundColor: context.colors.ivoryLight,
                          eyeStyle: QrEyeStyle(
                            eyeShape: QrEyeShape.square,
                            color: context.colors.slateDark,
                          ),
                          dataModuleStyle: QrDataModuleStyle(
                            dataModuleShape: QrDataModuleShape.square,
                            color: context.colors.slateDark,
                          ),
                        )
                      : Center(
                          child: _qrError == null
                              ? const CircularProgressIndicator()
                              : TrText(
                                  _qrError!,
                                  textAlign: TextAlign.center,
                                  style: context.type.captionMuted,
                                ),
                        ),
                ),
                if (_phase != _QrPhase.fresh)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: context.colors.ivoryLight.withValues(
                          alpha: 0.92,
                        ),
                        borderRadius: AppRadius.cardBorder,
                      ),
                      alignment: Alignment.center,
                      child: _phase == _QrPhase.scanned
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.phone_android_rounded,
                                  size: 30,
                                  color: context.colors.slateDark,
                                ),
                                const SizedBox(height: 10),
                                TrText(
                                  '已扫描',
                                  style: context.type.subheading.copyWith(
                                    fontSize: 18,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                TrText(
                                  '请在手机上确认',
                                  style: context.type.captionMuted,
                                ),
                              ],
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.hourglass_empty_rounded,
                                  size: 26,
                                  color: context.colors.cloudDark,
                                ),
                                const SizedBox(height: 10),
                                TrText(
                                  '二维码已过期',
                                  style: context.type.bodySm.copyWith(
                                    color: context.colors.cloudDark,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                IvoryButton(
                                  label: '刷新二维码',
                                  onPressed: _refresh,
                                ),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: TrText(
            _phase == _QrPhase.fresh ? '打开手机 App 扫描 · $_secondsLeft 秒后过期' : ' ',
            style: context.type.captionMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        BusyRow(
          busy: busy,
          child: switch (_phase) {
            _QrPhase.fresh =>
              url == null && _qrError != null
                  ? IvoryButton(label: '重试', onPressed: _refresh)
                  : const SizedBox.shrink(),
            _QrPhase.scanned => Column(
              children: [
                TrText(
                  '扫码成功 · 等待手机确认',
                  textAlign: TextAlign.center,
                  style: context.type.bodySm.copyWith(
                    color: context.colors.cloudDark,
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: TextLinkButton(
                    label: '返回二维码',
                    onPressed: () => setState(() => _phase = _QrPhase.fresh),
                  ),
                ),
              ],
            ),
            _QrPhase.expired => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 2 · SMS verification code
// ---------------------------------------------------------------------------

class SmsPanel extends StatefulWidget {
  const SmsPanel({super.key, required this.state});

  final AppState state;

  @override
  State<SmsPanel> createState() => _SmsPanelState();
}

class _SmsPanelState extends State<SmsPanel> with SignInFlow<SmsPanel> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _code = TextEditingController();
  Timer? _countdown;
  int _secondsLeft = 0;
  String? _phoneError;
  String? _codeError;

  @override
  void dispose() {
    _countdown?.cancel();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  void _sendCode() {
    if (!isValidPhone(_phone.text)) {
      setState(() => _phoneError = '请输入有效的 11 位手机号');
      return;
    }
    setState(() => _phoneError = null);
    unawaited(_send());
  }

  Future<void> _send() async {
    final String phone = digitsOf(_phone.text);
    final AuthOutcome outcome = await widget.state.sendSmsCode(phone);
    if (!mounted) return;
    if (!outcome.ok) {
      setState(() => _phoneError = outcome.error ?? '验证码发送失败');
      return;
    }
    setState(() => _secondsLeft = 60);
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return;
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) t.cancel();
      });
    });
  }

  void _submit() {
    bool ok = true;
    if (!isValidPhone(_phone.text)) {
      _phoneError = '请输入有效的 11 位手机号';
      ok = false;
    } else {
      _phoneError = null;
    }
    if (_secondsLeft <= 0) {
      _codeError = '请先获取验证码';
      ok = false;
    } else if (digitsOf(_code.text).length != 4) {
      _codeError = '验证码为 4 位数字';
      ok = false;
    } else {
      _codeError = null;
    }
    setState(() {});
    if (!ok) return;

    final String phone = digitsOf(_phone.text);
    unawaited(
      runSignIn(
        widget.state.signInWithPhoneCaptcha(phone, digitsOf(_code.text)),
        onError: (String error) => setState(() => _codeError = error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool counting = _secondsLeft > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneField(
          controller: _phone,
          errorText: _phoneError,
          onSubmitted: (_) => _sendCode(),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: PaperField(
                controller: _code,
                label: '验证码',
                hint: counting ? '查收短信验证码' : '4 位数字',
                errorText: _codeError,
                keyboardType: TextInputType.number,
                maxLength: 4,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.only(top: 22),
              child: OutlinedButton2(
                label: counting ? '$_secondsLeft 秒' : '获取验证码',
                onPressed: counting ? null : _sendCode,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        BusyRow(
          busy: busy,
          child: ClayButton(label: '登录', expand: true, onPressed: _submit),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 3 · Phone + password
// ---------------------------------------------------------------------------

class PasswordPanel extends StatefulWidget {
  const PasswordPanel({super.key, required this.state});

  final AppState state;

  @override
  State<PasswordPanel> createState() => _PasswordPanelState();
}

class _PasswordPanelState extends State<PasswordPanel>
    with SignInFlow<PasswordPanel> {
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _phoneError;
  String? _passwordError;
  bool _obscure = true;

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    bool ok = true;
    if (!isValidPhone(_phone.text)) {
      _phoneError = '请输入有效的 11 位手机号';
      ok = false;
    } else {
      _phoneError = null;
    }
    if (_password.text.length < 6) {
      _passwordError = '密码至少 6 位';
      ok = false;
    } else {
      _passwordError = null;
    }
    setState(() {});
    if (!ok) return;

    final String phone = digitsOf(_phone.text);
    unawaited(
      runSignIn(
        widget.state.signInWithPhonePassword(phone, _password.text),
        onError: (String error) => setState(() => _passwordError = error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneField(
          controller: _phone,
          errorText: _phoneError,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: AppSpacing.md),
        PaperField(
          controller: _password,
          label: '密码',
          hint: '至少 6 位',
          errorText: _passwordError,
          obscure: _obscure,
          onSubmitted: (_) => _submit(),
          prefix: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _obscure = !_obscure),
              child: Icon(
                _obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 17,
                color: context.colors.cloudDark,
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Align(
          alignment: Alignment.centerRight,
          child: TextLinkButton(label: '忘记密码？', onPressed: () {}),
        ),
        const SizedBox(height: AppSpacing.md),
        BusyRow(
          busy: busy,
          child: ClayButton(label: '登录', expand: true, onPressed: _submit),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 4 · Cookie import
// ---------------------------------------------------------------------------

class CookiePanel extends StatefulWidget {
  const CookiePanel({super.key, required this.state});

  final AppState state;

  @override
  State<CookiePanel> createState() => _CookiePanelState();
}

class _CookiePanelState extends State<CookiePanel>
    with SignInFlow<CookiePanel> {
  final TextEditingController _cookie = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _cookie.dispose();
    super.dispose();
  }

  void _submit() {
    final String raw = _cookie.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请粘贴 Cookie 字符串');
      return;
    }
    if (!raw.contains('=')) {
      setState(() => _error = '格式不正确 — 应包含键值对，例如 MUSIC_U=…');
      return;
    }
    setState(() => _error = null);

    unawaited(
      runSignIn(
        widget.state.signInWithCookie(raw),
        onError: (String error) => setState(() => _error = error),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PaperField(
          controller: _cookie,
          label: 'Cookie',
          hint: 'MUSIC_U=…; __csrf=…',
          errorText: _error,
          maxLines: 5,
          mono: true,
        ),
        const SizedBox(height: AppSpacing.sm),
        BusyRow(
          busy: busy,
          child: ClayButton(label: '登录', expand: true, onPressed: _submit),
        ),
        const SizedBox(height: AppSpacing.md),
        TrText(
          '从浏览器中复制网易云音乐的登录 Cookie，粘贴后会验证账户。',
          style: context.type.captionMuted.copyWith(height: 1.5),
        ),
      ],
    );
  }
}
