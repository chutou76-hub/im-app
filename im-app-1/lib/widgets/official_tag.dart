import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import 'v2_kit.dart'; // v2Scale

/// 「官方」标识（小助手 uid=-1 / 官方账号）。
///
/// 2026-10-07 需求4：**形态对齐「群聊」「频道」圆徽章**（实心圆底 + 白图标），
/// 三者只保留**颜色与图标**差异，视觉语言统一。改前本组件是「圆角矩形 + 浅蓝底 +
/// 蓝框 + 官方文字」，与群聊/频道的实心圆徽章不像同一套标识。
/// 尺寸规格对齐 `V2ConversationTag`：圆底 17×17、白图标 12。
class OfficialTag extends StatelessWidget {
  const OfficialTag({super.key, this.circular = true});

  /// true（默认，2026-10-07 起）= 圆徽章（与群聊/频道同款）；
  /// false = 旧形态（圆角矩形文字标签），保留给通讯录功能行等仍在用文字标签的位置。
  final bool circular;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    if (circular) {
      final s = v2Scale(context);
      return Container(
        width: 17 * s,
        height: 17 * s,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppTheme.primary,
          shape: BoxShape.circle,
        ),
        // 官方标记：verified（圆徽+勾，与蓝盾客服标区分）
        child: Icon(Icons.verified, size: 12 * s, color: Colors.white),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        border: Border.all(
            color: AppTheme.primary.withValues(alpha: 0.55), width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(t('officialTag'),
          style: const TextStyle(
              fontSize: 10,
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary)),
    );
  }
}