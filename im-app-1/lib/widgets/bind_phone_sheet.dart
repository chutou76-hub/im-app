import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/auth_service.dart';
import '../services/feature_flags.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';

/// 绑定手机号底部弹窗：显示当前手机号（若有）→ 输入新手机号 → 图形验证码 → 短信验证码 → 确认绑定。
///
/// 从 account_security_page.dart 的私有 `_BindPhoneSheet` 抽取为可复用公开组件（2026-11-02 需求4）。
///
/// 图形验证码联动（需求5）：是否展示/必填由 [FeatureFlags.instance.captchaOn] 控制。
///   - captchaOn=true：与历史行为一致，展示图形码、加载图形码、发码带 captchaId/captchaCode 且必填；
///   - captchaOn=false：隐藏图形码图片与输入框，发码时不传 captchaId/captchaCode（传空串），不再要求必填。
class BindPhoneSheet extends StatefulWidget {
  const BindPhoneSheet({super.key, this.currentPhone = ''});

  /// 当前已绑定的手机号（有则顶部提示，无则空）。
  final String currentPhone;

  @override
  State<BindPhoneSheet> createState() => _BindPhoneSheetState();
}

class _BindPhoneSheetState extends State<BindPhoneSheet> {
  final _svc = AuthService();
  final _phone = TextEditingController();
  final _captchaCode = TextEditingController();
  final _smsCode = TextEditingController();
  Captcha? _captcha;
  Uint8List? _captchaBytes; // 图形验证码解码一次，避免每秒重建闪烁
  int _left = 0;
  Timer? _timer;
  bool _loading = false;
  String _error = '';

  /// 图形验证码开关（需求5）：true 时展示图形码并要求必填；false 时隐藏且不校验。
  bool get _captchaOn => FeatureFlags.instance.captchaOn.value;

  @override
  void initState() {
    super.initState();
    // 需求5：仅当 captchaOn 开启时才预加载图形验证码
    if (_captchaOn) _loadCaptcha();
  }

  Future<void> _loadCaptcha() async {
    try {
      final c = await _svc.getCaptcha();
      if (!mounted) return;
      final bytes = base64Decode(c.imageBase64);
      setState(() {
        _captcha = c;
        _captchaBytes = bytes;
      });
    } catch (_) {}
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_left <= 1) {
        t.cancel();
        setState(() => _left = 0);
      } else {
        setState(() => _left--);
      }
    });
  }

  Future<void> _send() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (phone.isEmpty) {
      setState(() => _error = '请填写手机号');
      return;
    }
    // 需求5：仅当 captchaOn 开启时才校验图形验证码
    if (_captchaOn) {
      if (_captcha == null) {
        setState(() => _error = '图形验证码加载中，请稍候');
        return;
      }
      if (_captchaCode.text.trim().isEmpty) {
        setState(() => _error = '请先填写图形验证码');
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      // 需求5：captchaOn 关闭时传空串，由后端跳过图形码校验
      final captchaId = _captchaOn ? (_captcha?.captchaId ?? '') : '';
      final captchaCode = _captchaOn ? _captchaCode.text.trim() : '';
      await _svc.sendBindPhoneCode(phone, '+86', captchaId, captchaCode);
      if (!mounted) return;
      setState(() => _left = 60);
      _start();
      AppDialogs.toast(context, t('codeSent'));
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final t = AppLocalizations.of(context).t;
    final phone = _phone.text.trim();
    if (_smsCode.text.trim().isEmpty) {
      setState(() => _error = '请填写短信验证码');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await _svc.bindPhone(phone, '+86', _smsCode.text.trim());
      if (!mounted) return;
      AppDialogs.toast(context, t('acctSecBindSuccess'));
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _phone.dispose();
    _captchaCode.dispose();
    _smsCode.dispose();
    super.dispose();
  }

  Widget _field(TextEditingController c, String hint, {TextInputType? kt}) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: c,
      keyboardType: kt,
      style: TextStyle(fontSize: 15, color: scheme.onSurface),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontSize: 15,
            color: isDark ? scheme.outlineVariant : const Color(0xFFAAAAAA)),
        filled: true,
        fillColor:
            isDark ? scheme.surfaceContainerHighest : const Color(0xFFF7F8FA),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = AppTheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('acctSecBindPhone'),
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface)),
          const SizedBox(height: 12),
          if (widget.currentPhone.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? scheme.surfaceContainerHighest
                    : const Color(0xFFF7F8FA),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                  '${t('acctSecCurrentPhone')}：${widget.currentPhone}',
                  style: TextStyle(
                      fontSize: 13, color: scheme.onSurfaceVariant)),
            ),
          if (widget.currentPhone.isNotEmpty) const SizedBox(height: 12),
          _field(_phone, t('acctSecPhoneHint'), kt: TextInputType.phone),
          const SizedBox(height: 10),
          // 需求5：仅当 captchaOn 开启时展示图形验证码输入行
          if (_captchaOn) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _field(_captchaCode, t('graphicCaptcha')),
                ),
                const SizedBox(width: 10),
                GestureDetector(
                  onTap: _loadCaptcha,
                  child: Container(
                    width: 112,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: isDark
                              ? scheme.outlineVariant
                              : const Color(0xFFE2E5EA)),
                      color: isDark
                          ? scheme.surfaceContainerHighest
                          : const Color(0xFFF7F8FA),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: _captchaBytes == null
                          ? const Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                            )
                          : Image.memory(
                              _captchaBytes!,
                              fit: BoxFit.fill,
                              errorBuilder: (_, __, ___) =>
                                  const Icon(Icons.refresh),
                            ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child:
                    _field(_smsCode, t('smsCode'), kt: TextInputType.number),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: (_left > 0 || _loading) ? null : _send,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primary,
                    foregroundColor: Colors.white,
                    disabledForegroundColor: scheme.onSurfaceVariant,
                    disabledBackgroundColor: isDark
                        ? scheme.surfaceContainerHighest
                        : const Color(0xFFEDEFF2),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(
                    _left > 0 ? '$_left s' : t('sendCode'),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFDEAEA),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: AppTheme.danger.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      size: 18, color: AppTheme.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error,
                      style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.danger,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton(
              onPressed: _loading ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: primary,
              ),
              child: Text(t('acctSecBindConfirm')),
            ),
          ),
        ],
      ),
    );
  }
}
