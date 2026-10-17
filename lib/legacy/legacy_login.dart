import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';

/// Sign-in for the legacy shell: the scan card the Lazer login overlay shows,
/// drawn with the legacy palette, plus the cookie escape hatch.
Future<void> showLegacyLoginDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black54,
    builder: (BuildContext context) => _LegacyLoginDialog(state: state),
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
      setState(() => _error = outcome.error ?? '这个 Cookie 无效或已过期。');
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
    final ColorScheme scheme = theme.colorScheme;
    return Dialog(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text('登录', style: theme.textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
                ],
              ),
              Text(
                _cookieMode ? '粘贴浏览器里网易云音乐的登录 Cookie。' : '使用网易云音乐 App 扫描二维码登录。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 18),
              if (_cookieMode) ..._cookieFields(theme) else ..._qrFields(theme),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _qrFields(ThemeData theme) {
    final ColorScheme scheme = theme.colorScheme;
    final String? url = _url;
    return [
      Center(
        child: Container(
          width: 208,
          height: 208,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          clipBehavior: Clip.antiAlias,
          child: url == null
              ? Center(
                  child: _phase == _Phase.creating
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          Icons.qr_code_2_rounded,
                          size: 40,
                          color: scheme.onSurfaceVariant,
                        ),
                )
              : QrImageView(
                  data: url,
                  padding: const EdgeInsets.all(12),
                  backgroundColor: Colors.white,
                ),
        ),
      ),
      const SizedBox(height: 14),
      Center(
        child: Text(
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
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      if (_phase == _Phase.expired || _phase == _Phase.error) ...[
        const SizedBox(height: 12),
        Center(
          child: FilledButton.tonal(
            onPressed: _start,
            child: const Text('刷新二维码'),
          ),
        ),
      ],
      const SizedBox(height: 10),
      Center(
        child: TextButton(
          onPressed: () => setState(() => _cookieMode = true),
          child: const Text('使用 Cookie 登录'),
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
        decoration: const InputDecoration(hintText: 'MUSIC_U=…; __csrf=…'),
      ),
      if (_error != null) ...[
        const SizedBox(height: 8),
        Text(
          _error!,
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
            : const Text('登录'),
      ),
      const SizedBox(height: 4),
      TextButton(
        onPressed: () => setState(() => _cookieMode = false),
        child: const Text('返回扫码登录'),
      ),
    ];
  }
}
