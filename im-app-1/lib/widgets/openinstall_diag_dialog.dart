import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/openinstall_service.dart';
import '../theme/app_theme.dart';

/// 免填邀请码排障弹窗（2026-11-11 新增，2026-11-11 晚已停用入口）。
///
/// 背景：接入 Opo SDK 期间，为了不连电脑、不跑 adb 就能看到 SDK 收到了什么，
/// 做了一个「启动 3 秒后自动弹出 + 注册页按钮」的诊断框。2026-11-11 23:56
/// 真机报告确认链路已通（`bindData={"inviteCode":"..."}`，注册页自动填入），
/// 用户要求隐藏，故 **main.dart 与 register_page.dart 的入口均已移除**。
///
/// 目前没有调用方，仅为排障留档：以后线上再出现「装完不带邀请码」，
/// 在 main.dart 的 `runApp` 之后重新加一句
/// `if (OpenInstallService.instance.verboseEnabled) { ... showOpenInstallDiagDialog(ctx); }`
/// 并用 `--dart-define=OPENINSTALL_DEBUG=true` 构建即可复用。
/// 弹窗内容来自 [OpenInstallService.diagnostics]，随 SDK 回调实时刷新
/// （监听 `diagRevision`），底部「复制全部」一键拷走。
Future<void> showOpenInstallDiagDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const OpenInstallDiagDialog(),
  );
}

class OpenInstallDiagDialog extends StatefulWidget {
  const OpenInstallDiagDialog({super.key});

  @override
  State<OpenInstallDiagDialog> createState() => _OpenInstallDiagDialogState();
}

class _OpenInstallDiagDialogState extends State<OpenInstallDiagDialog> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copyAll() async {
    final text = OpenInstallService.instance.diagnostics();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final svc = OpenInstallService.instance;
    final maxH = MediaQuery.of(context).size.height * 0.58;
    return Dialog(
      backgroundColor: AppTheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ===== 标题 + 状态徽标 =====
            ValueListenableBuilder<int>(
              valueListenable: svc.diagRevision,
              builder: (_, __, ___) {
                final done = svc.isSettled;
                return Row(
                  children: [
                    const Icon(Icons.bug_report_outlined,
                        size: 20, color: AppTheme.primary),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        'OpenInstall 诊断',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (done ? AppTheme.success : AppTheme.warning)
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!done)
                            const SizedBox(
                              width: 10,
                              height: 10,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: AppTheme.warning,
                              ),
                            )
                          else
                            const Icon(Icons.check_circle,
                                size: 11, color: AppTheme.success),
                          const SizedBox(width: 4),
                          Text(
                            done ? '已完成' : '检测中',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: done ? AppTheme.success : AppTheme.warning,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 4),
            const Text(
              '把下面整段复制发给开发，就能定位卡在哪一步（不用连电脑）。',
              style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
            ),
            const SizedBox(height: 10),
            // ===== 报告正文（实时刷新） =====
            ValueListenableBuilder<int>(
              valueListenable: svc.diagRevision,
              builder: (_, __, ___) {
                return Container(
                  width: double.infinity,
                  constraints: BoxConstraints(maxHeight: maxH),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      svc.diagnostics(),
                      style: const TextStyle(
                        fontSize: 11,
                        height: 1.45,
                        fontFamily: 'monospace',
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // ===== 操作 =====
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 42,
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.ltOutline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text(
                        '关闭',
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 42,
                    child: ElevatedButton(
                      onPressed: _copyAll,
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _copied ? AppTheme.success : AppTheme.primary,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        _copied ? '已复制，发给开发即可' : '复制全部',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
