import 'package:flutter/material.dart';

/// 2026-11-07 三页新版式统一 Design Tokens（对照设计稿 moments.html /
/// profile.html / notifications.html 的 :root 变量）。
/// 仅朋友圈 / 互动通知 / 用户资料三个页面使用，不影响全局 AppTheme。
class D2026 {
  // ===== 主色 =====
  static const Color primary = Color(0xFF4C8BF5);
  static const Color primaryStrong = Color(0xFF2F6BE0);
  static const Color primarySoft = Color(0xFFEAF1FE);

  // ===== 强调色（点赞 / 性别徽标） =====
  static const Color accent = Color(0xFFFF7A9A);
  static const Color accentSoft = Color(0xFFFFEAF0);

  // ===== 状态色 =====
  static const Color online = Color(0xFF34C759);
  static const Color offline = Color(0xFF9CA3AF);
  static const Color error = Color(0xFFFF453A);
  static const Color paid = Color(0xFFE8923A); // 付费通过按钮（暖金实色）

  // ===== 中性色 =====
  static const Color bg = Color(0xFFF4F6FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surface2 = Color(0xFFF8FAFC);
  static const Color text1 = Color(0xFF16182B);
  static const Color text2 = Color(0xFF5B6172);
  static const Color text3 = Color(0xFF9AA1B2);
  static const Color outline = Color(0xFFE6E9F0);
  static const Color outline2 = Color(0xFFEEF1F6);
  static const Color socialBg = Color(0xFFF2F4F8); // 点赞/评论社交盒底

  // ===== 圆角 =====
  static const double rSm = 10;
  static const double rMd = 16;
  static const double rLg = 22;

  // ===== 卡片阴影（克制两层） =====
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
        color: Color(0x0D16182B), // rgba(22,24,43,.05)
        offset: Offset(0, 1),
        blurRadius: 2),
    BoxShadow(
        color: Color(0x0F16182B), // rgba(22,24,43,.06)
        offset: Offset(0, 8),
        blurRadius: 24),
  ];

  static const List<BoxShadow> floatShadow = [
    BoxShadow(
        color: Color(0x1F16182B), // rgba(22,24,43,.12)
        offset: Offset(0, 6),
        blurRadius: 16),
  ];

  /// 头像兜底色变体 a1-a6（蓝/粉/绿/橙/紫/青），按用户 ID 取模选色；
  /// 有真实头像 URL 时直接显示网络头像（AppAvatar 自带）。
  static const List<Color> avatarVariants = [
    Color(0xFF4C8BF5), // a1 蓝
    Color(0xFFFF7A9A), // a2 粉
    Color(0xFF52C07A), // a3 绿
    Color(0xFFFF9F43), // a4 橙
    Color(0xFF7B61FF), // a5 紫
    Color(0xFF34B6C2), // a6 青
  ];

  static Color avatarBg(String id) {
    final seed = id.trim().isEmpty ? '?' : id.trim();
    return avatarVariants[seed.hashCode.abs() % avatarVariants.length];
  }

  /// 秒 → mm:ss（视频时长角标，朋友圈发布弹层与帖子卡共用）
  static String fmtDuration(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
