import '../widgets/app_back_button.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/e2ee_service.dart'; // E2EE 开关 + 改密 re-wrap（§36）
import '../widgets/e2ee_unlock_sheet.dart'; // 开启前解锁/建钥弹窗（2026-10-10）
import '../services/wide_layout_store.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/bind_phone_sheet.dart'; // 绑定手机弹窗（2026-11-02 需求4：从本文件抽取为公开组件）
import 'login_page.dart';
import 'pay_pwd_setup_page.dart';

/// 账号安全：修改登录密码 / 注销账户
class AccountSecurityPage extends StatefulWidget {
  const AccountSecurityPage({super.key});

  @override
  State<AccountSecurityPage> createState() => _AccountSecurityPageState();
}

class _AccountSecurityPageState extends State<AccountSecurityPage> {
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  // E2EE（§36）：后台模式为 e2ee 且已建钥时显示用户级开关
  bool _e2eeVisible = false;
  bool _e2eeOn = true;
  // 强制开启（e2ee_mode=e2ee）：后台已强制，开关禁用（不允许关闭）
  bool _e2eeForced = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadE2ee();
  }

  Future<void> _loadE2ee() async {
    await E2eeService.instance.ensureLoaded();
    final me = await E2eeService.instance.meInfo();
    if (!mounted) return;
    setState(() {
      _e2eeVisible = me != null && me['mode'] == 'e2ee';
      // 2026-10-10：不再要求 hasKeys==true 才显示——登录时静默建钥失败的
      // 用户此前连开关都看不到（「开启不了端到端加密」）；现在开启动作本身
      // 会弹窗引导输入账号密码完成建钥/解锁。
      _e2eeOn = me?['e2eeOn'] != false;
      // 强制口径：mode=e2ee 且服务端标记 forced → 开关禁用（不可关闭）
      _e2eeForced = me?['forced'] == true;
    });
  }

  /// 拉取资料以显示当前已绑定的手机号
  Future<void> _loadProfile() async {
    try {
      final r = await _api.get('/api/v1/user/profile');
      final d = (r.data as Map<String, dynamic>)['data'];
      if (d is Map<String, dynamic> && mounted) {
        setState(() => _profile = d);
      }
    } catch (_) {}
  }

  Future<void> _bindPhone() async {
    final current =
        (_profile?['phone']?.toString() ?? '').trim();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => BindPhoneSheet(currentPhone: current),
    );
    if (ok == true && mounted) {
      await _loadProfile();
    }
  }

  bool _validPwd(String p) {
    final n = p.runes.length; // 按字符数计，与后端 len([]rune(p)) 一致
    return n >= 6 && n <= 20;
  }

  Widget _field(TextEditingController c, String hint) => TextField(
        controller: c,
        obscureText: true,
        style: const TextStyle(fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
          filled: true,
          fillColor: Theme.of(context).scaffoldBackgroundColor,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none),
        ),
      );

  Future<void> _changePassword() async {
    final t = AppLocalizations.of(context).t;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('acctSecChangePassword'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
              const SizedBox(height: 16),
              _field(oldCtrl, t('acctSecOldPwdHint')),
              const SizedBox(height: 12),
              _field(newCtrl, t('acctSecNewPwdHint')),
              const SizedBox(height: 12),
              _field(confirmCtrl, t('acctSecConfirmPwdHint')),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style:
                      FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  child: Text(t('acctSecConfirmChange')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    final oldP = oldCtrl.text;
    final newP = newCtrl.text;
    final confirmP = confirmCtrl.text;
    if (newP != confirmP) {
      AppDialogs.toast(context, t('acctSecPwdMismatch'));
      return;
    }
    if (!_validPwd(newP)) {
      AppDialogs.toast(context, t('acctSecPwdInvalid'));
      return;
    }
    // E2EE（§36）：已有私钥备份 → 先用旧密码解私钥、新密码 re-wrap，
    // 新密文随改密请求同事务落库；本地解不开（旧密码错）直接终止。
    String? encPriv;
    try {
      encPriv = await E2eeService.instance
          .rewrapForPasswordChange(oldPassword: oldP, newPassword: newP);
    } catch (_) {
      AppDialogs.toast(context, t('e2UnlockFailed'));
      return;
    }
    try {
      final token = await _api.readToken();
      final r = await _api.dio.put('/api/v1/user/password',
          data: {
            'oldPassword': oldP,
            'newPassword': newP,
            if (encPriv != null) 'encPriv': encPriv,
          },
          options: Options(headers: {'Authorization': 'Bearer $token'}));
      final code = (r.data as Map)['code'];
      if (code == 0) {
        AppDialogs.toast(context, t('acctSecPwdChanged'));
        // 宽屏右栏打开时不能直接 pop（会弹掉根路由黑屏）→ closeDetail
        if (mounted) closeDetail(context);
      } else if (code == 4401) {
        AppDialogs.toast(context, t('e2BackupRequired'));
      } else {
        AppDialogs.toast(
            context,
            ((r.data as Map)['message'] ??
                    AppLocalizations.of(context).t('acctSecChangeFailed'))
                .toString());
      }
    } catch (_) {
      AppDialogs.toast(context, t('acctSecChangeFailedRetry'));
    }
  }

  Future<void> _deleteAccount() async {
    final t = AppLocalizations.of(context).t;
    final yes = await AppDialogs.confirm(
      context,
      title: t('acctSecDeleteAccount'),
      message: t('acctSecDeleteAccountMsg'),
      confirmText: t('acctSecDeleteConfirm'),
      danger: true,
    );
    if (yes != true) return;
    try {
      final token = await _api.readToken();
      final r = await _api.dio.delete('/api/v1/user',
          options: Options(headers: {'Authorization': 'Bearer $token'}));
      final code = (r.data as Map)['code'];
      if (code == 0) {
        await _api.logout();
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const LoginPage()),
            (route) => false,
          );
        }
        return;
      }
      AppDialogs.toast(
          context,
          ((r.data as Map)['message'] ??
                  AppLocalizations.of(context).t('acctSecDeleteFailed'))
              .toString());
    } catch (_) {
      AppDialogs.toast(context, t('acctSecDeleteFailedRetry'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(leading: const AppBackButton(), title: Text(t('acctSecTitle'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: context.cs.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_android_outlined,
                      color: AppTheme.purple),
                  title: Text(t('acctSecBindPhone'),
                      style: const TextStyle(fontSize: 15)),
                  subtitle: _profile != null &&
                          (_profile!['phone']?.toString() ?? '').isNotEmpty
                      ? Text(_profile!['phone'].toString(),
                          style: TextStyle(
                              fontSize: 12, color: context.cs.onSurfaceVariant))
                      : null,
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _bindPhone,
                ),
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading:
                      const Icon(Icons.lock_outline, color: AppTheme.purple),
                  title: Text(t('acctSecChangePassword'),
                      style: const TextStyle(fontSize: 15)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _changePassword,
                ),
                // E2EE 用户级开关（§36 拍板③：默认开、可关）；
                // 仅后台加密方式为「端到端」且已建钥时显示；
                // 强制口径：mode=e2ee 且后台 forced 时禁用开关 + 提示文案
                if (_e2eeVisible) ...[
                  const Divider(height: 1, indent: 50),
                  ListTile(
                    leading: const Icon(Icons.enhanced_encryption,
                        color: AppTheme.purple),
                    title: Text(t('e2ToggleTitle'),
                        style: const TextStyle(fontSize: 15)),
                    subtitle: Text(
                        _e2eeForced
                            ? t('e2ToggleForcedSub')
                            : t('e2ToggleSub'),
                        style: TextStyle(
                            fontSize: 12,
                            color: _e2eeForced
                                ? context.cs.primary
                                : context.cs.onSurfaceVariant)),
                    trailing: Switch(
                      value: _e2eeOn,
                      activeColor: AppTheme.primary,
                      // 强制开启时禁用交互（服务端 toggle 也会拒绝，双重拦截）
                      onChanged: _e2eeForced
                          ? null
                          : (v) async {
                        // 2026-10-10 需求：开启端到端加密前必须「本机私钥就绪 +
                        // 服务端有密钥行」——任一不满足都弹「解锁/建钥」弹窗
                        //（输入账号原密码；弹窗内循环重试，多次输错引导重置密钥）。
                        // ⚠️ 不能只看本机 isReady：测试库清空/管理员烧备份后，
                        // 本机私钥可能残留就绪，但服务端无行 → toggle 必失败，
                        // 此前正是这条路径没弹窗、直接 toast「密码错误或解锁失败」。
                        if (v) {
                          final me =
                              await E2eeService.instance.meInfo();
                          await E2eeService.instance.ensureLoaded();
                          if (!mounted) return;
                          final serverHasKeys = me?['hasKeys'] == true;
                          if (!E2eeService.instance.isReady ||
                              !serverHasKeys) {
                            final unlocked =
                                await E2eeUnlockSheet.show(context);
                            if (!unlocked || !mounted) return;
                          }
                        }
                        // 2026-10-10：开启失败直接展示后端原始 message
                        //（网络/状态缺失可区分），不再笼统「开启失败」
                        final err =
                            await E2eeService.instance.setToggle(v);
                        if (!mounted) return;
                        if (err == null) {
                          setState(() => _e2eeOn = v);
                        } else {
                          AppDialogs.toast(context, err);
                        }
                      },
                    ),
                  ),
                ],
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading:
                      const Icon(Icons.lock_outline, color: AppTheme.purple),
                  title: Text(t('payPwdSetEntry'),
                      style: const TextStyle(fontSize: 15)),
                  subtitle: UserCache.myProfileData?['payPwdSet'] == true
                      ? Text(t('payPwdSetDone'),
                          style: TextStyle(
                              fontSize: 12, color: context.cs.onSurfaceVariant))
                      : null,
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const PayPwdSetupPage()));
                    if (mounted) setState(() {}); // 返回时刷新「已设置」状态
                  },
                ),
                const Divider(height: 1, indent: 50),
                ListTile(
                  leading: const Icon(Icons.delete_forever_outlined,
                      color: AppTheme.danger),
                  title: Text(t('acctSecDeleteAccount'),
                      style: const TextStyle(
                          fontSize: 15, color: AppTheme.danger)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: context.cs.onSurfaceVariant),
                  onTap: _deleteAccount,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
