import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'v2_kit.dart';

// V2 复刻的小标签组（2026-09-14 批次：消息列表 / 通讯录两页共用）。
//
// 尺寸来自参考截图的像素级实测（逻辑 px，基准宽 420），全部经 `v2Scale` 等比缩放。
// 参考包里没有这几个标签的图片资源（`assets/icons` 下只有 tab_*.png），
// 所以直接用「填充块 + 文字」画，不用图标字体。

/// 蓝V 认证盾的蓝色（截图实测 #3A93EE；通讯录页实测 #4498ED，差异在 JPEG 噪声内）。
const Color kV2VerifiedBlue = Color(0xFF3A93EE);

/// 会话类型小徽章：群聊 = 红色圆底白图标；频道 = 蓝色圆底白图标。
///
/// 2026-09-15 第十七批（Telegram 风格参考截图）：原「实心蓝底文字『群聊』/
/// 浅蓝底文字『频道』」改为**小圆底图标徽章**——与参考图名称前的星形圆徽
/// 同构。圆 17、图标 ink 12；群聊沿用群名红 #DC4E52（深色 #FF7A7E），
/// 频道沿用主题蓝 AppTheme.primary #007AFF（深色 #409CFF），与两色频道名
/// 形成同色呼应。图标：群聊 `Icons.groups`；频道 `Icons.campaign`（与
/// 新建频道页头像同图标，广播语义辨识度最高）。位置由调用方统一放名称前
/// （chat_list_page 群/频道均已在名称前）。
class V2ConversationTag extends StatelessWidget {
  const V2ConversationTag({
    super.key,
    this.kind = V2ConversationTagKind.group,
  });

  final V2ConversationTagKind kind;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final dark = context.v2IsDark;
    final isGroup = kind == V2ConversationTagKind.group;
    final bg = isGroup
        ? (dark ? const Color(0xFFFF7A7E) : const Color(0xFFDC4E52))
        : (dark ? const Color(0xFF409CFF) : AppTheme.primary);
    return Container(
      width: 17 * s,
      height: 17 * s,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Icon(
        isGroup ? Icons.groups : Icons.campaign,
        size: 12 * s,
        color: Colors.white,
      ),
    );
  }
}

enum V2ConversationTagKind { group, channel }

/// 蓝V 认证盾（会话名后面的那枚）。
///
/// 实测 ink 18.0 × 20.7（宽/高 0.87 ⇒ 盾形，不是正圆徽章），
/// 所以选 Material 的 `verified_user`（盾 + 对勾），而不是 `verified`（圆徽章）。
class V2VerifiedShield extends StatelessWidget {
  const V2VerifiedShield({super.key, this.size = 24, this.color});

  /// 图标**盒子**尺寸（不是 ink 尺寸）。默认 24 时 ink 约 18×20.7，与实测一致。
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.verified_user,
      size: size * v2Scale(context),
      color: color ?? kV2VerifiedBlue,
    );
  }
}

/// 靓号皇冠徽（2026-09-15 第十四批）。
///
/// 用户拍板：蓝色勾保留给客服（[CertBadge]），靓号 `vipShortId` 改用**金色皇冠**
/// 区分。Material 无纯皇冠图标，取 `workspace_premium`（勋章绶带形，观感最接近）；
/// 金色 #F5A623，与蓝色客服勾明确区分。
const Color kV2VipGold = Color(0xFFF5A623);

class VipCrownBadge extends StatelessWidget {
  const VipCrownBadge({super.key, this.size = 24, this.color});

  /// 图标**盒子**尺寸（与 [V2VerifiedShield] 同口径）。
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.workspace_premium,
      size: size * v2Scale(context),
      color: color ?? kV2VipGold,
    );
  }
}

/// 会员专属标识（2026-10-06 需求15 权益 badge）：金色「VIP」小牌。
/// 五处统一：我的页 / 消息列表 / 通讯录 / 好友资料 / 聊天标题栏（头像角标另配小号）。
/// 显示条件由调用方判定：自己=VipStore（isVipActive+hasBadge）；
//    他人=后端 vipBadge（PublicUser）/ peerVipBadge（ConvList）字段。
/// 2026-10-10 需求：VIP/SVIP 区分显示——svip=true 显示「SVIP」紫金牌。
class VipNameBadge extends StatelessWidget {
  const VipNameBadge(
      {super.key, this.height = 17, this.fontSize = 12, this.svip = false});

  /// 牌高近似值（由内边距+字号推出的视觉高度口径，与客服 V 盾 17/18 同级）
  final double height;

  /// VIP 字号
  final double fontSize;

  /// true=SVIP 档（后端 vipLevel/peerVipLevel==2）：文字「SVIP」+ 紫底，与金 VIP 区分
  final bool svip;

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final k = height / 17; // 相对默认尺寸缩放（头像角标用 14/17≈0.82）
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: 7 * s * k, vertical: 2.5 * s * k),
      decoration: BoxDecoration(
        color: svip ? const Color(0xFF6D28D9) : const Color(0xFFC9A227),
        borderRadius: BorderRadius.circular(9 * s * k),
      ),
      child: Text(svip ? 'SVIP' : 'VIP',
          style: TextStyle(
              fontSize: fontSize * s * k,
              fontWeight: FontWeight.w800,
              height: 1.0,
              color: Colors.white)),
    );
  }
}

/// 会话类型文字标签（2026-10-07 需求1）
///
/// 消息列表里区分「群聊 / 频道 / 官方 / 官方客服」的第二标识，显示在**昵称后面**。
/// 设计口径：**纯文字 + 颜色区分，不用图标**——四种类型同款圆角小牌，
/// 只有文案与颜色不同，视觉语言统一（此前群聊/频道是圆形图标徽章、官方是
/// 圆角矩形文字牌、客服是蓝盾勾，四者形态各异）。
class ConvKindTextTag extends StatelessWidget {
  final String label;
  final Color color;
  /// 深色模式（浅底文字会看不清）；不传则按主题亮度自动判断
  final bool? dark;
  const ConvKindTextTag({
    super.key,
    required this.label,
    required this.color,
    this.dark,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = dark ??
        Theme.of(context).brightness == Brightness.dark;
    // 深色模式用提亮字，保证暗底可读
    final fg = isDark ? Color.lerp(color, Colors.white, 0.45)! : color;
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: 4 * v2Scale(context), vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.20 : 0.10),
        borderRadius: BorderRadius.circular(4 * v2Scale(context)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10 * v2Scale(context),
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}

/// 会员标识圆徽章（2026-10-07 需求5）。
///
/// **来源**：用户中心（me_page）头像右下角的 VIP 皇冠角标 —— 金渐变圆底（#FFD54F→#FF8F00）
/// + 白描边 + 白皇冠图标。本组件把它抽成公共件，供聊天页等处复用，**避免各端各画一套**。
///
/// VIP 与 SVIP 用**图标**区分（不再显示 VIP / SVIP 文字）：
///   - VIP：金色皇冠 `workspace_premium`
///   - SVIP：SVIP 金两色（皇冠+ 星芒），用 `auto_awesome` 星芒叠加表达高一级
class VipBadgeDot extends StatelessWidget {
  final bool svip;
  /// 圆徽直径（逻辑 px，不含 v2 缩放）
  final double size;
  const VipBadgeDot({super.key, this.svip = false, this.size = 30});

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    final d = size * s;
    return Container(
      width: d,
      height: d,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // SVIP 用更亮的一档金，视觉上高一级
        gradient: LinearGradient(
          colors: svip
              ? const [Color(0xFFFFF176), Color(0xFFFFA000)]
              : const [Color(0xFFFFD54F), Color(0xFFFF8F00)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2 * s),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFFF8F00).withValues(alpha: 0.4),
            blurRadius: 6 * s,
            offset: Offset(0, 2 * s),
          ),
        ],
      ),
      child: Icon(
        svip ? Icons.auto_awesome : Icons.workspace_premium,
        size: d * 0.54,
        color: Colors.white,
      ),
    );
  }
}

/// 客服认证徽（V 盾）公共判定 + 展示（2026-09-15 第十三批）。/// 背景：用户反馈「客服账号没有勾图标」——通讯录里的勾此前只认
/// `vipShortId`（靓号），与客服身份无关。这里把「账号角色=客服才亮 V 盾」
/// 的判定抽成一处，供 消息列表 / 好友资料页 / 聊天窗口 复用。
///
/// ⚠️ role 语义：PublicUser.role = **账号角色**（1 普通 / 2 管理 / 3 客服，
/// im-server `RoleKefu=3`）。群成员列表里的 `role` 是**群内角色**
/// （1 群主 2 管理员 3 普通成员），同名不同义，**不得**传入本组件。
class CertBadge extends StatelessWidget {
  const CertBadge({super.key, required this.role, this.size = 24});

  /// 对方账号角色（PublicUser.role / 会话列表 peerRole），数字或字符串均可。
  final dynamic role;

  /// 图标盒子尺寸（与 [V2VerifiedShield] 同口径）。
  final double size;

  /// 是否客服（RoleKefu=3）。兼容数字 / 字符串两种下发形态。
  static bool isKefu(dynamic role) => role == 3 || role?.toString() == '3';

  @override
  Widget build(BuildContext context) {
    if (!isKefu(role)) return const SizedBox.shrink();
    // 样式与通讯录现有勾一致（V2VerifiedShield 默认蓝）
    return V2VerifiedShield(size: size);
  }
}
