import 'package:flutter/material.dart';

/// 全 App 统一返回按钮（2026-10-08）。
///
/// **统一为 `Icons.arrow_back_ios_new`（B 型「细雪佛龙<」）**，与聊天窗口一致。
///
/// 背景：项目里曾混用两种合法设计稿规格 —— `V2SetBackSpec.full`
/// （A 型 `Icons.arrow_back`，完整 ←）与 `V2SetBackSpec.chevron`
/// （B 型 `Icons.arrow_back_ios_new`，细雪佛龙 <）。同一 App 内返回键形态不一致，
/// 用户明确要求**全部统一成聊天窗口那一种**（B 型）。
///
/// 用法（放在 `AppBar` 的 `leading`，替换 Material 默认返回键）：
/// ```dart
/// AppBar(leading: const AppBackButton(), title: ...)
/// ```
/// 也可用于页面内自定义顶栏：
/// ```dart
/// IconButton(icon: AppBackIcon(), onPressed: () => Navigator.of(context).maybePop())
/// ```
class AppBackButton extends StatelessWidget {
  /// 图标边长（逻辑 px）。与聊天窗口 `chat_page.dart` 的 26 保持一致。
  static const double iconSize = 26;

  /// 图标颜色；null 时取当前主题的前景色（跟随深/浅色）
  final Color? color;

  /// 点击行为，默认 `Navigator.maybePop()`
  final VoidCallback? onPressed;

  const AppBackButton({super.key, this.color, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(Icons.arrow_back_ios_new,
          size: iconSize, color: color ?? IconTheme.of(context).color),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
    );
  }
}

/// 返回图标（供页面自定义顶栏/IconButton 复用同一形态）
class AppBackIcon extends StatelessWidget {
  final Color? color;
  const AppBackIcon({super.key, this.color});

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.arrow_back_ios_new,
          size: AppBackButton.iconSize, color: color ?? IconTheme.of(context).color);
}
