import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_localizations.dart';
import '../state/app_state.dart';
import '../theme/apple_design.dart';

/// Present the sign-in card in the Apple sheet language.
Future<void> showLegacyLoginDialog(BuildContext context, AppState state) {
  final Brightness brightness = Theme.of(context).brightness;
  final Color accent = state.legacyAccentSeed ?? AppleColors.musicRed;
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: .32),
    builder: (BuildContext context) => Theme(
      data: buildAppleTheme(brightness: brightness, seedAccent: accent),
      child: _LegacyLoginDialog(state: state),
    ),
  );
}

enum _Phase { creating, waiting, scanned, expired, error }

class _LegacyLoginDialog extends StatefulWidget {
  const _LegacyLoginDialog({required this.state});

  final AppState state;

  @override
  State<_LegacyLoginDialog> createState() => _LegacyLoginDialogState();
}

class _LegacyLoginDialogState extends State<_LegacyLoginDialog> {
  _Phase _phase = _Phase.creating;
  String? _url;
  Timer? _poll;
  bool _polling = false;
  bool _cookieMode = false;
  final TextEditingController _cookie = TextEditingController();
  bool _submitting = false;
  String? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    _poll?.cancel();
    setState(() {
      _phase = _Phase.creating;
      _url = null;
      _error = null;
    });
    final String? url = await state.beginQrLogin();
    if (!mounted) return;
    setState(() {
      _url = url;
      _phase = url == null ? _Phase.error : _Phase.waiting;
    });
    if (url != null) {
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _tick(url));
      unawaited(_tick(url));
    }
  }

  Future<void> _tick(String url) async {
    if (_polling || !mounted) return;
    _polling = true;
    try {
      final int code = await state.pollQrLogin(url);
      if (!mounted) return;
      if (code == 803) {
        _poll?.cancel();
        Navigator.of(context).maybePop();
        return;
      }
      setState(() {
        if (code == 800) {
          _phase = _Phase.expired;
          _poll?.cancel();
        } else if (code == 802 || code == 8821) {
          _phase = _Phase.scanned;
        }
      });
    } finally {
      _polling = false;
    }
  }

  Future<void> _submitCookie() async {
    final String value = _cookie.text.trim();
    if (value.isEmpty || _submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final AuthOutcome outcome = await state.signInWithCookie(value);
    if (!mounted) return;
    setState(() => _submitting = false);
    if (outcome.ok) {
      Navigator.of(context).maybePop();
    } else {
      setState(() => _error = outcome.error ?? '这个 Cookie 无效或已过期。');  // i18n:key
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _cookie.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 370),
        decoration: BoxDecoration(
          color: apple.tertiaryBackground,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: apple.separator, width: .5),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: .3),
              blurRadius: 44,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TrText(
                    '登录',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: apple.label,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: context.tr('取消'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
              ],
            ),
            Text(
              context.tr(
                _cookieMode
                    ? '粘贴浏览器里网易云音乐的登录 Cookie。'
                    : '使用网易云音乐 App 扫描二维码登录。',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: apple.secondaryLabel,
              ),
            ),
            const SizedBox(height: 18),
            if (_cookieMode) ..._cookieFields(theme) else ..._qrFields(theme),
          ],
        ),
      ),
    );
  }

  List<Widget> _qrFields(ThemeData theme) {
    final AppleSemanticColors apple = AppleSemanticColors.of(context);
    final String? url = _url;
    return [
      Center(
        child: Container(
          width: 204,
          height: 204,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: apple.separator, width: .5),
          ),
          clipBehavior: Clip.antiAlias,
          child: url == null
              ? Center(
                  child: _phase == _Phase.creating
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.qr_code_2_rounded,
                          size: 40,
                          color: apple.tertiaryLabel,
                        ),
                )
              : QrImageView(
                  data: url,
                  padding: EdgeInsets.zero,
                  backgroundColor: Colors.white,
                ),
        ),
      ),
      const SizedBox(height: 14),
      Center(
        child: TrText(
          switch (_phase) {
            _Phase.creating => '正在生成二维码…',
            _Phase.waiting => '打开 App 扫描二维码',
            _Phase.scanned => '已扫描，请在手机上确认',
            _Phase.expired => '二维码已过期',
            _Phase.error => '二维码获取失败，请检查网络后重试。',
          },
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: _phase == _Phase.scanned
                ? apple.accent
                : apple.secondaryLabel,
          ),
        ),
      ),
      if (_phase == _Phase.expired || _phase == _Phase.error) ...<Widget>[
        const SizedBox(height: 12),
        Center(
          child: FilledButton(
            onPressed: _start,
            child: TrText('刷新二维码'),
          ),
        ),
      ],
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          onPressed: () => setState(() => _cookieMode = true),
          child: TrText('使用 Cookie 登录'),
        ),
      ),
    ];
  }

  List<Widget> _cookieFields(ThemeData theme) {
    return [
      TextField(
        controller: _cookie,
        minLines: 3,
        maxLines: 5,
        autofocus: true,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          height: 1.5,
        ),
        decoration: const InputDecoration(hintText: 'MUSIC_U=…  __csrf=…'),
      ),
      if (_error != null) ...<Widget>[
        const SizedBox(height: 8),
        Text(
          context.tr(_error!),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
      ],
      const SizedBox(height: 14),
      FilledButton(
        onPressed: _submitting ? null : _submitCookie,
        child: _submitting
            ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TrText('登录'),
      ),
      const SizedBox(height: 4),
      TextButton(
        onPressed: () => setState(() => _cookieMode = false),
        child: TrText('返回扫码登录'),
      ),
    ];
  }
}
