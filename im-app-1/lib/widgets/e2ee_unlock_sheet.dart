import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/e2ee_service.dart';
import '../theme/app_theme.dart';
import 'app_dialogs.dart';

/// E2EE 解锁/建钥弹窗（§36，2026-10-10 需求改版）。
///
/// 场景：
/// - 服务端已有密钥备份 → 输入**账号登录密码**解锁备份恢复本机私钥；
/// - 服务端无密钥（hasKeys=false，如登录时静默建钥失败）→ 输入账号密码
///   直接**生成新密钥对**并以此密码包裹备份上云（等同首次建钥）。
///
/// 交互（2026-10-10 用户需求）：解锁在弹窗**内部**完成并循环重试——
/// 失败红字提示、可反复输入；累计失败 ≥3 次醒目引导「重置密钥」
///（重置=用当前输入的密码生成全新密钥覆盖上云，旧加密历史不可再解）。
/// 返回 true = 本机私钥已就绪（解锁/建钥/重置任一路径成功）。
class E2eeUnlockSheet {
  E2eeUnlockSheet._();

  /// 连续失败达到该次数后，弹窗内出现醒目的重置引导。
  static const int _retryGuideAfter = 3;

  static Future<bool> show(BuildContext context) async {
    final t = AppLocalizations.of(context).t;
    final ctrl = TextEditingController();
    final st = _SheetState();
    // 预检：服务端是否已有密钥（决定本次输入密码是「解锁备份」还是「新建密钥」）
    final me = await E2eeService.instance.meInfo();
    if (!context.mounted) return false;
    final hasKeys = me?['hasKeys'] == true;
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
              Text(t(hasKeys ? 'e2UnlockTitle' : 'e2SetupTitle'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
              const SizedBox(height: 8),
              Text(t(hasKeys ? 'e2UnlockHint' : 'e2SetupHint'),
                  style: TextStyle(
                      fontSize: 13, color: context.cs.onSurfaceVariant)),
              const SizedBox(height: 14),
              TextField(
                controller: ctrl,
                obscureText: true,
                autofocus: true,
                enabled: !st.busy,
                onSubmitted: (_) =>
                    _submit(ctx, setSheet, ctrl, hasKeys, st),
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: t('e2UnlockPwdHint'),
                  hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                  filled: true,
                  fillColor: Theme.of(ctx).scaffoldBackgroundColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              if (st.err != null) ...[
                const SizedBox(height: 10),
                Text(st.err!,
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.danger)),
              ],
              // 2026-10-10 需求：多次输错 → 醒目引导重置（旧备份作废、
              // 此前加密历史无法再解；重置前确认弹窗会再次明示代价）
              if (st.fails >= _retryGuideAfter) ...[
                const SizedBox(height: 10),
                Text(t('e2RetryHint'),
                    style: const TextStyle(
                        fontSize: 13, color: AppTheme.danger)),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed:
                      st.busy ? null : () => _submit(ctx, setSheet, ctrl, hasKeys, st),
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary),
                  child: st.busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(t('e2UnlockBtn')),
                ),
              ),
              // 重置入口：已有密钥时才有「重置」意义（无密钥=首次建钥，密码输对即可）
              if (hasKeys)
                Center(
                  child: TextButton(
                    onPressed: st.busy
                        ? null
                        : () async {
                            final confirmed = await AppDialogs.confirm(
                              ctx,
                              title: t('e2ResetKeys'),
                              message: t('e2ResetConfirm'),
                              danger: true,
                            );
                            if (confirmed != true) return;
                            final done = await E2eeService.instance
                                .resetKeys(ctrl.text);
                            if (!ctx.mounted) return;
                            if (done) {
                              Navigator.pop(ctx, true);
                            } else {
                              st.busy = false;
                              st.err = t('e2ResetFailed');
                              setSheet(() {});
                            }
                          },
                    child: Text(t('e2ResetKeys'),
                        style: TextStyle(
                            fontSize: 13,
                            color: st.fails >= _retryGuideAfter
                                ? AppTheme.danger
                                : context.cs.onSurfaceVariant,
                            fontWeight: st.fails >= _retryGuideAfter
                                ? FontWeight.w600
                                : FontWeight.w400)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return ok == true;
  }

  /// 弹窗内的可变状态（StatefulBuilder 各闭包共享同一实例）。
  static Future<void> _submit(
      BuildContext ctx,
      void Function(void Function()) setSheet,
      TextEditingController ctrl,
      bool hasKeys,
      _SheetState st) async {
    final t = AppLocalizations.of(ctx).t;
    final pwd = ctrl.text.trim();
    if (pwd.isEmpty) return;
    st.busy = true;
    st.err = null;
    setSheet(() {});
    // 已有密钥 → 解锁备份；无密钥 → 用该密码首次建钥（resetKeys 即
    // 「生成新密钥对+密码包裹+PUT /e2ee/keys 上云+本机就绪」，建钥/重置两用）
    final success = hasKeys
        ? await E2eeService.instance.unlockWithPassword(pwd)
        : await E2eeService.instance.resetKeys(pwd);
    if (!ctx.mounted) return;
    if (success) {
      Navigator.pop(ctx, true);
      return;
    }
    st.busy = false;
    st.fails++;
    st.err = t('e2UnlockFailed');
    setSheet(() {});
  }
}

class _SheetState {
  int fails = 0;
  bool busy = false;
  String? err;
}
