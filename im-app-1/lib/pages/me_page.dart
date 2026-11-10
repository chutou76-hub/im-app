import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/call_service.dart';
import '../services/feature_flags.dart';
import '../services/friend_service.dart';
import '../services/settings_service.dart';
import '../services/update_service.dart';
import '../services/user_cache.dart';
import '../services/vip_store.dart'; // 会员权益缓存（2026-10-06 需求13）
import '../services/wide_layout_store.dart';
import '../services/wallet_store.dart';
import '../services/ws_service.dart';
import '../widgets/bind_phone_sheet.dart'; // 绑定手机弹窗（2026-11-02 需求4：统一复用公共组件）
import '../widgets/lang_picker.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_seal_badge.dart';
import '../widgets/v2_tags.dart'; // CertBadge.isKefu（客服判定公共口径）
import 'about_page.dart';
import 'chat_settings_page.dart';
import 'data_storage_page.dart';
import 'device_page.dart';
import 'edit_profile_page.dart';
import 'favorites_page.dart';
import 'invite_promotion_page.dart'; // 邀请推广中心（2026-11-11 需求1，全民邀请码模式）
import 'login_page.dart';
import 'my_qr_page.dart';
import 'notification_settings_page.dart';
import 'privacy_settings_page.dart';
import 'shop_page.dart';
import 'system_settings_page.dart';
import 'wallet_page.dart';

/// 我的（设计稿：顶部蓝色涂鸦插画 + 头像/昵称 + 白色圆角主体 + 分组设置卡片）
///
/// 布局基准与参考截图一致：本页**不放 AppBar、不用 SafeArea**（由 HomeShell 直接
/// 铺满全屏），蓝色插画因此能延伸到状态栏之下（沉浸式）；所有纵向基准以
/// **屏幕顶部为 0**。尺寸取自 UI-ref 的像素级实测（截图逻辑宽 420 / DPR 3），
/// 横向尺寸乘 [v2Scale] 等比缩放到当前屏宽，让窄屏上「元素与屏宽的比例」
/// 与截图一致。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

/// 一行设置项：彩色图标块 + 标题（+ 可选副标题）+ 右侧箭头。
class _GoldTag extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _GoldTag({
    required this.text,
    this.bg = const Color(0x14FF8F00),
    this.fg = const Color(0xFFFF8F00),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1.1,
            color: fg),
      ),
    );
  }
}

class _MeRowSpec {
  const _MeRowSpec({
    required this.fill,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    // 2026-10-07 需求（对齐设计稿 user-center.html .row-vip）：
    // VIP 行金色高亮（浅金渐变底 + 左侧金色竖条 + 金色标题）；仅 VIP 行开，其他行不变
    this.goldAccent = false,
  });

  final Color fill; // 图标块填充色（截图实测）
  final IconData icon; // 块内白色图形
  final String title;
  final String? subtitle;
  final Widget? trailing; // 行尾信息（余额 / 邀请码等）
  final VoidCallback onTap;
  final bool goldAccent; // VIP 金色高亮行
}

class _MePageState extends State<MePage> {
  // ===== 纵向基准（逻辑 px，屏幕顶部为 0，截图实测）=====
  static const double _blueH = 413.7; // 蓝底块高（含 sheet 圆角外的角缺口）
  static const double _sheetTop = 387.7; // 主体 sheet 顶边
  static const double _sheetRadius = 32.8; // sheet 顶角圆角
  static const double _sheetTopPad =
      32.0; // sheet 顶 → 第一张卡片（2026-09-15 紧凑：41→32）
  static const double _cardGap = 24.0; // 卡与卡之间（2026-09-15 紧凑：32→24）
  static const double _versionGap = 32.0; // 最后一张卡 → 版本号（46→32）
  static const double _bottomPad = 120.0; // 底部留白：让版本号能滚到浮动 Tab 胶囊上方

  // ===== 卡片 / 行（逻辑 px）=====
  static const double _cardGutter = 20.7; // 卡片左右外边距
  static const double _cardRadius = 23.0;
  static const double _rowVPad = 14.5; // 行上下内边距
  static const double _iconLeft = 17.7; // 图标块距卡片左缘
  static const double _iconBox = 44.0;
  static const double _iconRadius = 10.0;
  static const double _textLeft = 101.0; // 标题/副标题 ink 左缘
  static const double _chevronGutter = 20.0; // chevron 图标框右缘 → 卡片右缘
  static const double _sepIndent = 79.0; // 分隔线左内缩（距卡片左缘）

  // ===== 色值（截图实测）=====
  static const Color _blueTop = Color(0xFF75BEF5);
  static const Color _blueBottom = Color(0xFF4FA1E1);
  static const Color _pageBg = Color(0xFFF6F7F9);
  static const Color _cardBg = Color(0xFFFFFFFF);
  static const Color _titleInk = Color(0xFF141926);
  static const Color _subInk = Color(0xFFA0A4AD);
  static const Color _chevronInk = Color(0xFF9EA3AE);
  static const Color _separator = Color(0xFFE5E5E5);
  static const Color _versionInk = Color(0xFFA0A4AE);
  static const Color _btnFill = Color(0xFFF4F9FF); // 顶部两个按钮填充（非纯白）
  static const Color _btnInk = Color(0xFF213655);
  static const Color _danger = Color(0xFFFF3B2F);

  // 13 行入口的图标块填充色（iOS 系统色系，截图实测）
  static const Color _orange = Color(0xFFFF9501);
  static const Color _indigo = Color(0xFF5855D6);
  static const Color _gray = Color(0xFF8F8E93);
  static const Color _green = Color(0xFF34C85A);
  static const Color _nearBlack = Color(0xFF0C0D12);
  static const Color _purple = Color(0xFFAF52DE);
  // 2026-10-07 需求：VIP 入口金色高亮（对齐设计稿 user-center.html .row-vip）
  static const Color _goldDark = Color(0xFFFF8F00);
  static const Color _goldBright = Color(0xFFFFD54F);
  static const LinearGradient _goldGradient = LinearGradient(
    colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  /// 头像右上角 VIP 皇冠角标填充（设计稿 .vip-badge），点击进 VIP 页
  static const LinearGradient _goldBadgeGradient = LinearGradient(
    colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const Color _blue = Color(0xFF007AFF);

  final _svc = FriendService();
  final _api = ApiClient.instance;
  Map<String, dynamic>? _profile;
  String _inviteCode = ''; // 我的邀请码（用户中心展示 + 点击复制）
  String _brandName = ''; // 底部版本号里的品牌名（读后台 authConfig 本地缓存）

  @override
  void initState() {
    super.initState();
    // 立刻用全局身份缓存垫底：登录后消息列表/通讯录已拉过我的资料并写入 UserCache，
    // 这里直接显示，避免 profile 接口偶发抖动时"我的"页闪/卡在"未登录"。
    final ident = UserCache.myProfileData;
    if (ident != null) _profile = ident;
    _loadCachedProfile();
    _loadCachedBrand();
    _load();
    _refreshBalance();
    // 功能开关（零钱/邀请码）：后台可实时开关，进入本页刷新一次
    FeatureFlags.instance.load();
    // 会员权益缓存（2026-10-06 需求13）：聊天撤回可见/徽标等处读取；
    // VIP 开关开启才拉（关闭时接口 4017，权益视为空）
    if (FeatureFlags.instance.vipOn.value) VipStore.instance.refresh();
  }

  /// 先读本地缓存的资料，首帧直接渲染昵称/头像，
  /// 修复「快速切到'我的'先显示'未登录'/默认头像，接口回来才变」。
  /// 网络返回后再覆盖刷新（缓存只做展示兜底，不阻断更新）。
  Future<void> _loadCachedProfile() async {
    try {
      final raw = await _api.readPref('profile');
      if (raw == null || raw.isEmpty || !mounted) return;
      final cached = jsonDecode(raw);
      if (cached is Map<String, dynamic> &&
          _profile == null &&
          (cached['id']?.toString() ?? '').isNotEmpty) {
        setState(() => _profile = cached);
      }
    } catch (_) {}
  }

  /// 底部版本号里的品牌名：与「关于」页同源（后台 authConfig）。
  /// 先读本地缓存垫底；**缓存没有（用户没进过关于页）时直连 /auth/config 拉一次
  /// 并落盘**——以前只读缓存，没进过「关于」页就一直回落 ChatPulse（二十七批需求5）。
  Future<void> _loadCachedBrand() async {
    try {
      final raw = await _api.readPref('authConfig');
      if (raw != null && raw.isNotEmpty && mounted) {
        final d = jsonDecode(raw);
        if (d is Map) {
          final b = (d['brandName'] ?? d['appName'] ?? '').toString();
          if (b.isNotEmpty) setState(() => _brandName = b);
        }
      }
    } catch (_) {}
    if (!mounted || _brandName.isNotEmpty) return; // 缓存已命中就不打接口
    try {
      final r = await _api.get('/api/v1/auth/config');
      final d =
          (r.data as Map<String, dynamic>)['data'] as Map<String, dynamic>? ??
              {};
      final b = (d['brandName'] ?? d['appName'] ?? '').toString();
      if (!mounted) return;
      if (b.isNotEmpty) setState(() => _brandName = b);
      if (d.isNotEmpty) {
        unawaited(_api.writePref('authConfig', jsonEncode(d))); // 与「关于」页同源落盘
      }
    } catch (_) {}
  }

  /// 钱包余额走后端（"我的钱包"行 trailing 展示）。
  /// B-20：以前只在 initState 拉一次，而本页常驻在 HomeShell 的 _pages 里不销毁，
  /// 后台给用户加了余额后 App 里永远是旧值。改为可重复调用（切回"我的" tab 时会触发）。
  Future<void> _refreshBalance() async {
    await WalletStore.instance.refresh();
    if (mounted) setState(() {});
  }

  /// 下拉刷新：重新拉资料 + 余额。
  /// 主链路是服务端 WS 主动推送（B-24），这里只是给用户一个"手动刷新"的入口，
  /// 同时也兜住 WS 断开 / 推送丢失的情况。
  Future<void> _onPullRefresh() async {
    await Future.wait([_load(), _refreshBalance()]);
  }

  Future<void> _load({int retry = 0}) async {
    try {
      final p = await _svc.profile();
      if (mounted) {
        setState(() {
          _profile = p;
          _inviteCode = p['myInviteCode']?.toString() ?? '';
        });
        // 同步全局身份缓存：供失败兜底，也避免其他页面再拉一遍
        UserCache.setMyProfile(p);
        // 资料写入本地缓存，下次进 App / 切 tab 首帧即有昵称头像
        unawaited(_api.writePref('profile', jsonEncode(p)));
      }
    } catch (e) {
      // 首次请求偶发超时（服务端瞬时慢，与登录/进群超时同款）→ 自动重试，
      // 否则"我的"页会一直显示"未登录"，直到手动下拉刷新
      if (retry < 2 && mounted) {
        await Future.delayed(Duration(milliseconds: 600 * (retry + 1)));
        if (!mounted) return;
        return _load(retry: retry + 1);
      }
      // 重试耗尽也不应卡在"未登录"：用全局身份缓存（消息列表/通讯录已拉过）兜底
      if (mounted) {
        final fallback = UserCache.myProfileData;
        if (fallback != null) setState(() => _profile = fallback);
      }
    }
  }

  Future<void> _logout() async {
    final t = AppLocalizations.of(context).t;
    final confirm = await AppDialogs.confirm(
      context,
      title: t('meLogoutTitle'),
      message: t('meLogoutMsg'),
      confirmText: t('meLogoutConfirm'),
      danger: true,
    );
    if (confirm != true) return;
    // 关键：退出登录必须清干净全局态，否则再登录会白屏 / 复用上一个账号的连接。
    // 1) CallService：清通话态 + 关悬浮小窗 + 释放 TRTC 引擎 + 清空 _myId
    // 2) GlobalWs：断开 WS 并清空监听列表（原连接带的是旧 token）
    // 两步都套 3s 超时兜底（B-18）：局部清理失败/卡住也必须把用户送到登录页，
    // 不能出现"点了退出登录没反应"。
    await CallService.instance
        .resetSession()
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    GlobalWs.instance.close();
    // 这里不要再单独 close 一次浮窗：resetSession 已经在关了，
    // 重复调用反而会撞上"插件不回 result → await 永久挂起"的坑（B-18）。
    // ApiClient.logout 内部已改成"先清本地 token，再通知服务端"，
    // 所以这里压到 2s 也只是放弃服务端通知，不影响本地已登出。
    await _api.logout().timeout(const Duration(seconds: 2), onTimeout: () {});
    UserCache.clear(); // 清用户信息缓存：换账号登录不能复用上一个会话的数据
    // 钱包：清内存余额（磁盘快照已由 logout→LocalStore.clearUserData 清）。
    // 不清的话换账号登录后、refresh() 返回前会短暂显示上一个人的余额。
    WalletStore.instance.reset();
    if (!mounted) return;
    // 用 pushAndRemoveUntil 清栈，避免回退键还能回到已登出的首页
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final s = v2Scale(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 已登录时绝不应显示"未登录"：优先用本页 profile，再退回全局身份缓存
    // （profile 接口偶发抖动时，消息列表/通讯录早已写入 UserCache，可兜底显示真实昵称）。
    final p = _profile ?? UserCache.myProfileData;
    final name = (p?['nickname']?.toString() ?? '').isNotEmpty
        ? p!['nickname'].toString()
        : t('meNotLoggedIn');
    final account = p?['account']?.toString() ?? '';
    final shortId = p?['shortId']?.toString() ?? '';
    // 靓号标识：short_id 来自后台靓号池（已分配）
    final isVipShort = p?['vipShortId'] == true && shortId.isNotEmpty;
    // VIP 生效中（2026-10-05 需求）：profile 带 vipExpireAt（可空），到期时间在
    // 当前时间之后即视为 VIP——已开通则用户中心隐藏「VIP 购买」入口
    final vipExpireAt = DateTime.tryParse('${p?['vipExpireAt'] ?? ''}');
    final isVipActive = vipExpireAt != null && vipExpireAt.isAfter(DateTime.now());
    // 2026-10-07：头像皇冠角标 = VIP **或** SVIP 有效才显示（普通用户不显示）。
    // 会员状态口径统一走 VipStore（VIP/SVIP 独立判定，10s TTL 缓存，_load 时已 refresh），
    // 不依赖 profile 是否下发 svipExpireAt。
    final isSvipActive = VipStore.instance.svipActive;
    final showVipCrown = isVipActive || isSvipActive;
    final pageBg = dark ? Theme.of(context).scaffoldBackgroundColor : _pageBg;

    // 头部高度（2026-11-13 三 tab 间距统一·紧凑化）：原「去掉底部导航后剩余
    // 高度的一半」偏高（蓝底占半屏），与消息/通讯录两 tab 的紧凑观感不符，
    // 用户要求三页统一收紧——改为剩余高度的 **40%**。hv 从目标高度反推
    // （headerH = _blueH * s * hv），内部全部纵向坐标/内容尺寸
    // 继续随 sv = s * hv 等比缩放：任意屏高下蓝底占可用区 40%，
    // 头像/二维码/编辑按钮/字号随之铺开不重叠（0.40~1.40 防极端屏形挤压/拉伸）。
    final screenH = MediaQuery.sizeOf(context).height;
    final navH = (83.7 + 30) * s;
    final headerH = (screenH - navH) * 0.40;
    final hv = (headerH / (_blueH * s)).clamp(0.40, 1.40);

    return Scaffold(
      backgroundColor: pageBg,
      // 本页无 AppBar / SafeArea：蓝色插画从 y=0 起铺满（沉浸到状态栏之下），
      // 底部浮动 Tab 胶囊由 HomeShell 用 Stack 盖在上面，所以这里只留出滚动内边距。
      body: RefreshIndicator(
        onRefresh: _onPullRefresh,
        color: scheme.primary,
        backgroundColor: pageBg,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            _headerBoard(s, hv, t, name, p, account, shortId, isVipShort,
                isVipActive, showVipCrown, isSvipActive),
            // 主体 sheet：与页面同色的圆角容器盖在蓝底上（顶角 R=32.8，露出蓝色角缺口），
            // 上移 (_blueH - _sheetTop) * hv 让 sheet 顶边正好落在 387.7 * hv。
            Transform.translate(
              offset: Offset(0, -(_blueH - _sheetTop) * s * hv),
              child: Container(
                decoration: BoxDecoration(
                  color: pageBg,
                  borderRadius: BorderRadius.vertical(
                      top: Radius.circular(_sheetRadius * s)),
                ),
                child: Column(
                  children: [
                    SizedBox(height: _sheetTopPad * s),
                    // 卡片 A：账号 / 钱包 / 会员 / 通知 / 隐私 / 存储 / 邀请码
                    // 功能开关实时驱动：后台关闭「零钱/邀请码」后立即隐藏对应入口
                    AnimatedBuilder(
                      animation: Listenable.merge([
                        FeatureFlags.instance.walletOn,
                        FeatureFlags.instance.inviteOn,
                        // 邀请码模式变化也要刷新入口行（2026-11-11 需求1）
                        FeatureFlags.instance.inviteUniversal,
                        // 商城/会员开关（2026-10-05）：后台关闭后入口即时隐藏
                        FeatureFlags.instance.shopOn,
                        FeatureFlags.instance.vipOn,
                      ]),
                      builder: (_, __) => _card(s, dark, [
                        // 完善登录账号（绑手机）：已绑定手机的用户不显示（二十七批需求2）
                        if (!(p?['phone']?.toString() ?? '').trim().isNotEmpty)
                          _MeRowSpec(
                            fill: _danger,
                            icon: Icons.error_outline,
                            title: t('meRowCompleteAccount'),
                            subtitle: t('meSubCompleteAccount'),
                            // 2026-09-14 需求2：由「进账号安全页」改为**直接弹绑定手机号码面板**。
                            // 账号安全页（改登录密码 / 注销账户）入口没丢：仍在「编辑资料」页里。
                            onTap: _showBindPhoneSheet,
                          ),
                        if (FeatureFlags.instance.walletOn.value)
                          _MeRowSpec(
                            fill: _orange,
                            icon: Icons.account_balance_wallet_outlined,
                            title: t('meRowWallet'),
                            // 余额用监听而不是快照：后台改了余额 / 领了红包后不用手动 setState（B-20）
                            trailing: ValueListenableBuilder<double>(
                              valueListenable:
                                  WalletStore.instance.balanceNotifier,
                              builder: (_, v, __) => Text(
                                  '¥ ${WalletStore.instance.fmt(v)}',
                                  style: TextStyle(
                                      fontSize: 16.2 * s,
                                      color: dark
                                          ? scheme.onSurfaceVariant
                                          : _subInk)),
                            ),
                            onTap: _openWallet,
                          ),
                        // VIP 会员购买（2026-10-05 上线）：后台 vip_enabled 开启才显示；
                        // 同日需求：已开通 VIP（未过期）的用户隐藏此入口，不重复打扰
                        // 2026-10-07 需求：按设计稿 user-center.html 加金色高亮
                        //（浅金渐变底 + 左侧金条 + 金色图标/标题 + 行尾金色状态标签）；
                        // 同日再改：**删掉副标题**（2026-10-06-07 用户要求行高与
                        // 钱包/通知和声音等无描述行完全一致）
                        if (FeatureFlags.instance.vipOn.value && !isVipActive)
                          _MeRowSpec(
                            fill: _indigo,
                            goldAccent: true,
                            icon: Icons.workspace_premium_outlined,
                            title: t('meRowVip'),
                            trailing: _GoldTag(text: t('meSubVipInactive')),
                            onTap: _openVip,
                          ),
                        // 靓号商城（2026-10-05）：后台 shop_enabled 开启才显示；
                        // 同日需求：已有靓号（vipShortId）的用户隐藏此入口
                        // 2026-10-07 需求：紫色渐变图标块（设计稿 .icon-vanity）+
                        // 标题旁红色「热」标；同日再改：删掉副标题（行高对齐）
                        if (FeatureFlags.instance.shopOn.value && !isVipShort)
                          _MeRowSpec(
                            fill: _purple,
                            icon: Icons.auto_awesome,
                            title: t('meRowShop'),
                            trailing: const _GoldTag(
                                text: '热',
                                bg: Color(0xFFFFEBEE),
                                fg: Color(0xFFF44336)),
                            onTap: _openShop,
                          ),
                        // 添加好友价格入口 2026-11-07 需求3：移至「隐私」设置页最上方
                        _MeRowSpec(
                          fill: _danger,
                          icon: Icons.notifications_none,
                          title: t('meRowNotify'),
                          // 2026-09-14：原先指向 SystemSettingsPage，现按参考截图
                          // 改为独立的「通知和声音」页（V2 复刻）。
                          onTap: () => _openNotifySettings(),
                        ),
                        _MeRowSpec(
                          fill: _gray,
                          icon: Icons.lock_outline,
                          title: t('meRowPrivacy'),
                          // 2026-09-14 需求6：由「隐私政策全文（PolicyPage）」改为
                          // **V2 复刻的隐私设置页**；政策全文仍可从「关于」页进入。
                          onTap: _openPrivacySettings,
                        ),
                        _MeRowSpec(
                          fill: _green,
                          icon: Icons.cloud_outlined,
                          title: t('meRowStorage'),
                          // 2026-09-14：数据和存储页建出来后接线（原先只弹「敬请期待」）
                          onTap: _openDataStorage,
                        ),
                        if (FeatureFlags.instance.inviteOn.value)
                          _MeRowSpec(
                            fill: AppTheme.green,
                            icon: Icons.share_outlined,
                            // 2026-11-11 需求1：全民邀请码模式 → 入口改为
                            // 「邀请推广中心」二级页（推广总金额+邀请好友列表）；
                            // 指定邀请码模式 → 维持原行为（展示码、点击复制）
                            title: FeatureFlags.instance.inviteUniversal.value
                                ? t('meInvitePromotion')
                                : t('meInviteCode'),
                            subtitle:
                                FeatureFlags.instance.inviteUniversal.value
                                    ? null
                                    : (_inviteCode.isNotEmpty
                                        ? _inviteCode
                                        : null),
                            onTap: FeatureFlags.instance.inviteUniversal.value
                                ? _openInvitePromotion
                                : _copyInviteCode,
                          ),
                      ]),
                    ),
                    SizedBox(height: _cardGap * s),
                    // 卡片 B：聊天设置 / 设备（消息保活设置行已按 2026-09-15 用户要求删除）
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: _nearBlack,
                        icon: Icons.chat_bubble,
                        title: t('meRowChatSettings'),
                        onTap: _openChatSettings,
                      ),
                      _MeRowSpec(
                        fill: _orange,
                        icon: Icons.devices,
                        title: t('meRowDevice'),
                        // 固定文案，无数据源（参考截图即如此）
                        subtitle: t('meSubDeviceCount'),
                        onTap: _openDevice,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 卡片 C：语言 / 外观
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: _purple,
                        icon: Icons.language,
                        title: t('meSwitchLanguage'),
                        // 右侧显示当前语言（语言入口是弹窗菜单）
                        subtitle: _otherLangLabel(context),
                        onTap: () => _showLangPicker(context),
                      ),
                      _MeRowSpec(
                        fill: _blue,
                        icon: Icons.wb_sunny_outlined,
                        title: t('meRowAppearance'),
                        // 2026-09-14 需求8：改为底部弹「深色模式 / 浅色模式」选择面板。
                        // 数据源仍是 AppSettings.dark；全局主题由 main.dart 的
                        // `ctx.watch<AppSettings>()` 驱动，本行副标题靠 setState 跟着刷新。
                        subtitle: AppSettings.instance.dark
                            ? t('settingsDarkMode')
                            : t('settingsLightMode'),
                        onTap: _showAppearanceSheet,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 卡片 D：我的收藏 / 系统设置 / 关于（贴纸和表情、常见问题两行已按
                    // 2026-09-15 用户要求删除；两行原本只弹「敬请期待」，无页面文件）
                    // 2026-09-17 需求：我的收藏下方新增「系统设置」，
                    // 修改密码（账号安全）/ AI 翻译等功能收口进系统设置页。
                    _card(s, dark, [
                      _MeRowSpec(
                        fill: AppTheme.pink,
                        icon: Icons.favorite_border_rounded,
                        title: t('meFavorites'),
                        onTap: _openFavorites,
                      ),
                      _MeRowSpec(
                        fill: _indigo,
                        icon: Icons.settings_outlined,
                        title: t('settingsTitle'),
                        onTap: _openSystemSettings,
                      ),
                      _MeRowSpec(
                        fill: _gray,
                        icon: Icons.info_outline,
                        title: t('meRowAbout'),
                        onTap: _openAbout,
                      ),
                    ]),
                    SizedBox(height: _cardGap * s),
                    // 退出登录（截图无此行，属保留现有入口）
                    _cardShell(
                      s,
                      dark,
                      InkWell(
                        onTap: _logout,
                        borderRadius: BorderRadius.circular(_cardRadius * s),
                        child: SizedBox(
                          height: 73.0 * s,
                          child: Center(
                            child: Text(t('meLogoutTitle'),
                                style: TextStyle(
                                    fontSize: 19.4 * s,
                                    fontWeight: FontWeight.w500,
                                    height: 1.0,
                                    color: _danger)),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(height: _versionGap * s),
                    // 底部版本号（品牌名 + 版本）
                    Center(
                      child: Text(
                          '${_brandName.isEmpty ? 'ChatPulse' : _brandName} v${UpdateService.currentVersion}',
                          style: TextStyle(
                              fontSize: 16.1 * s,
                              fontWeight: FontWeight.w400,
                              height: 1.0,
                              color: dark
                                  ? scheme.onSurfaceVariant
                                  : _versionInk)),
                    ),
                    // 底部留白：让版本号能滚到浮动 Tab 胶囊（高 83.7 + 底距 30）上方
                    SizedBox(
                        height: _bottomPad * s +
                            MediaQuery.paddingOf(context).bottom),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =============== 顶部蓝色插画区 ===============

  /// 顶部插画区（参考高 413.7，按 [hv] 纵向自适应压缩）：蓝色渐变 + **参考图涂鸦
  /// 背景图**（`assets/me_header_doodle.png`，亮度→alpha 提取的白色线稿透明 PNG）+
  /// 二维码/编辑按钮 + 头像/昵称/副标题。
  ///
  /// 纵向坐标与内容尺寸（头像/字号/徽标）× `s * hv`；按钮尺寸保持 × s（触控目标不缩）。
  Widget _headerBoard(
      double s,
      double hv,
      dynamic Function(String, [Map<String, String>?]) t,
      String name,
      Map<String, dynamic>? p,
      String account,
      String shortId,
      bool isVipShort,
      bool isVipActive,
      // 2026-10-07：VIP/SVIP 任一有效即显示头像皇冠角标（普通用户不显示）
      bool showVipCrown,
      // 2026-10-07 需求5：SVIP 用星芒图标（VIP 用皇冠）
      bool isSvipActive) {
    final avatarUrl = p?['avatar']?.toString() ?? '';
    final bound = (p?['phone']?.toString() ?? '').trim().isNotEmpty;
    // 副标题里的 @handle 用**账号**（= 用户名），不是一信号（shortId）。shortId 仅在 account 为空时兜底。
    // 2026-09-15 需求：@账号 后面跟上短ID；2026-09-25 需求：前缀改大写「ID: 」。
    // 2026-09-25 需求2：删掉「已/未绑定手机」文案，改用图标标识——
    // 已绑定 = 绿色对勾盾（verified），未绑定 = 灰色禁用电话（phone_disabled）。
    // 2026-10-10 需求5：@账号 整段隐藏不再显示，副标题只留「ID: 短ID」
    //（原 idText/showPlainId 随之删除——后者本就无引用）。
    // 纵向综合系数：位置/头像/字号全部随压缩比例缩放（保证任意 hv 下不重叠）。
    final sv = s * hv;

    return SizedBox(
      height: _blueH * sv,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 蓝底：垂直线性渐变 #75BEF5 → #4FA1E1，全宽满铺（含状态栏区域），
          // 上面叠参考图涂鸦线稿（纯白透明 PNG，2026-09-15 需求：背景 = 颜色 + 背景图）。
          Positioned.fill(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [_blueTop, _blueBottom],
                ),
              ),
              child: Image.asset(
                'assets/me_header_doodle.png',
                fit: BoxFit.cover,
                // 资产加载失败退化为纯渐变，不挡登录
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
          // 二维码按钮：正圆 ∅55.7，x 28.7 / y 67.0（y 随 hv 压缩）
          Positioned(
            left: 28.7 * s,
            top: 67.0 * sv,
            child: _circleButton(s, Icons.qr_code_2, 55.7, 20.3, () {
              WideLayoutStore.instance.openDetail(context, const MyQrPage(),
                  paneKey: 'myqr', fadeScale: true);
            }),
          ),
          // 「编辑」胶囊：83.7×50.0，右外边距 29.0 / y 69.3（y 随 hv 压缩）
          Positioned(
            right: 29.0 * s,
            top: 69.3 * sv,
            child: _pillButton(s, t('chatListEdit'), _openProfile),
          ),
          // 头像：中心 (屏宽/2, 195.0)，外径 ∅142.8（白环 4.3 + 内圆 ∅134.2）+ 向下投影
          Positioned(
            top: (195.0 - 142.8 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  GestureDetector(
                    onTap: _openProfile,
                    child: Container(
                      width: 142.8 * sv,
                      height: 142.8 * sv,
                      padding: EdgeInsets.all(4.3 * sv),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF08212F)
                                .withValues(alpha: 0.18),
                            blurRadius: 20 * sv,
                            offset: Offset(0, 6 * sv),
                          ),
                        ],
                      ),
                      child: AppAvatar(
                        url: avatarUrl,
                        name: name,
                        size: 134.2 * sv,
                        radius: 134.2 / 2 * sv,
                        background: AppTheme.primary,
                      ),
                    ),
                  ),
                  // 2026-10-07 需求：头像**内**右下角 VIP 皇冠角标（设计稿 .vip-badge——
                  // 金渐变圆 + 白描边 + 皇冠），点击直达 VIP 页；放在 Stack 里与头像
                  // 同级，避免包裹头像 GestureDetector 影响原点击区。
                  // 仅 VIP/SVIP 任一有效时显示（普通用户不显示）；偏移按外径 142.8
                  // 折算，皇冠 30 压在圆环右下内侧。
                  if (showVipCrown)
                    Positioned(
                      right: 6 * sv,
                      bottom: 6 * sv,
                      // 2026-10-07 需求5：改用公共组件 VipBadgeDot（VIP/SVIP 用图标
                      // 区分，不再画 VIP/SVIP 文字），聊天页等处复用同一实现
                      child: GestureDetector(
                        onTap: _openVip,
                        child: VipBadgeDot(svip: isSvipActive, size: 30),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 昵称 32.9 / w700 / 白，居中（2026-09-15 需求：删掉昵称右侧的表情徽标）
          Positioned(
            top: (305.0 - 35.0 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _openProfile,
                child: SizedBox(
                  height: 35.0 * sv,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 32.9 * sv,
                                fontWeight: FontWeight.w700,
                                height: 1.0,
                                color: Colors.white)),
                      ),
                      // 客服标识：V2SealBadge 与好友资料页统一（二十六批需求）
                      // 仅自己的 role=3（客服账号）时显示，判定复用 CertBadge.isKefu
                      if (CertBadge.isKefu(p?['role'])) ...[
                        SizedBox(width: 8 * s),
                        const V2SealBadge(size: 23, color: Color(0xFF4FA4EE)),
                      ],
                      // 会员专属标识（2026-10-06 权益 badge）：VIP 有效且后台
                      // 「会员设置」勾选了「VIP 专属标识」才显示（金色小牌；
                      // 需求15：组件抽到 v2_tags.VipNameBadge，五处统一）
                      // 2026-10-10 需求：SVIP 显示紫色「SVIP」牌
                      if (isVipActive && VipStore.instance.hasBadge) ...[
                        SizedBox(width: 8 * s),
                        VipNameBadge(svip: VipStore.instance.svipActive),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 副标题：「[绑定图标] @账号 ID: 短ID」20.1 / w400 / 白 85%，整行居中
          // （2026-09-25 需求2：手机绑定态不再用文案，用图标——已绑定绿色对勾盾，
          // 未绑定灰色禁用电话；点一下复制 ID —— 保留原资料卡片上的复制入口）
          Positioned(
            top: (348.0 - 18.7 / 2) * sv,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                // 2026-10-05 需求：还没有靓号时点 ID 直接进靓号商城（引导购买）；
                // 已有靓号或商城未开启则维持原「复制 ID」行为
                onTap: () {
                  if (!isVipShort &&
                      FeatureFlags.instance.shopOn.value &&
                      shortId.isNotEmpty) {
                    _openShop();
                    return;
                  }
                  _copyId(shortId, account);
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24 * s),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        bound ? Icons.verified : Icons.phone_disabled,
                        size: 20.1 * sv,
                        color: bound
                            ? const Color(0xFF8FF0A4) // 蓝底上的浅绿：一眼「已绑定」
                            : Colors.white.withValues(alpha: 0.45),
                      ),
                      SizedBox(width: 5 * sv),
                      // 2026-10-10 需求5：@账号 文本删除（不再显示），
                      // 只保留绑定图标 + ID;靓号用户 ID 原位金色（kV2VipGold）
                      if (shortId.isNotEmpty)
                        Text(
                          'ID: $shortId',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 20.1 * sv,
                              fontWeight: isVipShort
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              height: 1.0,
                              color: isVipShort
                                  ? kV2VipGold
                                  : Colors.white.withValues(alpha: 0.85)),
                        ),
                      // 2026-10-07 需求：短 ID 后加「✨ 换靓号」快捷入口
                      // （设计稿 user-center.html .id-row .vanity-link，浅黄胶囊文字）。
                      // 独立 GestureDetector 嵌套在外层 ID 点击区里——Flutter 内层优先，
                      // 点胶囊进商城、点其余区域维持原「复制 ID / 无靓号进商城」行为。
                      if (FeatureFlags.instance.shopOn.value) ...[
                        SizedBox(width: 8 * sv),
                        GestureDetector(
                          onTap: _openShop,
                          child: Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 6 * sv, vertical: 2 * sv),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.auto_awesome,
                                    size: 13.5 * sv, color: _goldBright),
                                SizedBox(width: 3 * sv),
                                Text(
                                  t('meChangeVanity'),
                                  style: TextStyle(
                                      fontSize: 16.5 * sv,
                                      fontWeight: FontWeight.w600,
                                      height: 1.0,
                                      color: _goldBright),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 靓号金色徽标已移除（二十六批二轮）：靓号原位显示在副标题 id 位置
          // （金色高亮），不再重复放一枚徽标。
        ],
      ),
    );
  }

  /// 圆形按钮（二维码入口）：填充 #F4F9FF，图标 #213655
  Widget _circleButton(
      double s, IconData icon, double d, double iconSize, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: d * s,
        height: d * s,
        alignment: Alignment.center,
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: _btnFill),
        child: Icon(icon, size: iconSize * s, color: _btnInk),
      ),
    );
  }

  /// 胶囊按钮（编辑入口）：83.7×50.0，文字 19.5 / w500 / #203555
  Widget _pillButton(double s, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 83.7 * s,
        height: 50.0 * s,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _btnFill,
          borderRadius: BorderRadius.circular(25.0 * s),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 19.5 * s,
                fontWeight: FontWeight.w500,
                height: 1.0,
                color: _btnInk)),
      ),
    );
  }

  // =============== 设置卡片 / 行 ===============

  /// 卡片外壳：白底 + R23 + 极浅阴影（深色下用卡片底色、不投阴影）
  Widget _cardShell(double s, bool dark, Widget child) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: EdgeInsets.symmetric(horizontal: _cardGutter * s),
      decoration: BoxDecoration(
        color: dark ? scheme.surface : _cardBg,
        borderRadius: BorderRadius.circular(_cardRadius * s),
        boxShadow: dark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 14 * s,
                  offset: Offset(0, 4 * s),
                ),
              ],
      ),
      child: child,
    );
  }

  /// 分组卡片：若干行 + 行间分隔线（左内缩 79、右通到卡片边）
  Widget _card(double s, bool dark, List<_MeRowSpec> rows) {
    final separators =
        dark ? Theme.of(context).colorScheme.outlineVariant : _separator;
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(_row(s, dark, rows[i]));
      if (i != rows.length - 1) {
        children.add(Divider(
          height: 1,
          thickness: 1 * s,
          indent: _sepIndent * s,
          endIndent: 0.7 * s,
          color: separators,
        ));
      }
    }
    return _cardShell(s, dark, Column(children: children));
  }

  /// 单行：44×44 彩色图标块（R10）+ 标题/副标题 + 行尾信息 + chevron
  /// 2026-10-07：VIP 行按设计稿 .row-vip 加金色高亮——浅金渐变底 + 左侧 3px 金色
  /// 竖条（::before）+ 金色图标块/标题；深色模式用半透明金调，避免整行刺眼。
  Widget _row(double s, bool dark, _MeRowSpec r) {
    final scheme = Theme.of(context).colorScheme;
    final titleInk = dark ? scheme.onSurface : _titleInk;
    final subInk = dark ? scheme.onSurfaceVariant : _subInk;
    // 金色高亮：亮色 #FFF8E1→白 60%（设计稿 row-vip），暗色用金调半透明
    final goldBg = !r.goldAccent
        ? null
        : (dark
            ? LinearGradient(
                colors: [
                  _goldDark.withValues(alpha: 0.16),
                  scheme.surface.withValues(alpha: 0.0),
                ],
              )
            : const LinearGradient(
                colors: [Color(0xFFFFF8E1), Color(0xFFFFFFFF)],
                stops: [0.0, 0.6],
              ));
    final iconBox = Container(
      width: _iconBox * s,
      height: _iconBox * s,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // VIP 行图标块走金色渐变 + 金色柔光（设计稿 .row-vip .row-icon）
        gradient: r.goldAccent ? _goldGradient : null,
        color: r.goldAccent ? null : r.fill,
        borderRadius: BorderRadius.circular(_iconRadius * s),
        boxShadow: r.goldAccent
            ? [
                BoxShadow(
                  color: _goldDark.withValues(alpha: 0.35),
                  blurRadius: 8 * s,
                  offset: Offset(0, 3 * s),
                ),
              ]
            : null,
      ),
      child: Icon(r.icon, size: 23.0 * s, color: Colors.white),
    );
    final body = Row(
      children: [
        SizedBox(width: _iconLeft * s),
        iconBox,
        SizedBox(width: (_textLeft - _iconLeft - _iconBox) * s),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(r.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 19.4 * s,
                      fontWeight: FontWeight.w600,
                      height: 1.0,
                      color: r.goldAccent
                          ? (dark ? _goldBright : _goldDark)
                          : titleInk)),
              if (r.subtitle != null) ...[
                SizedBox(height: 8.6 * s),
                Text(r.subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 16.2 * s,
                        fontWeight: FontWeight.w400,
                        height: 1.28,
                        color: subInk)),
              ],
            ],
          ),
        ),
        if (r.trailing != null)
          Padding(
              padding: EdgeInsets.only(left: 8 * s), child: r.trailing!),
        SizedBox(width: 12.3 * s),
        Icon(Icons.chevron_right,
            size: 24 * s,
            color: dark ? scheme.onSurfaceVariant : _chevronInk),
        SizedBox(width: _chevronGutter * s),
      ],
    );
    // 金色行左侧竖条用 Stack 叠在行左侧（设计稿 row-vip::before）
    if (!r.goldAccent) {
      return InkWell(
          onTap: r.onTap,
          child: Padding(
              padding: EdgeInsets.symmetric(vertical: _rowVPad * s),
              child: body));
    }
    return Stack(
      children: [
        InkWell(
          onTap: r.onTap,
          child: Container(
            decoration: BoxDecoration(gradient: goldBg),
            padding: EdgeInsets.symmetric(vertical: _rowVPad * s),
            child: body,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 3 * s,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: _goldGradient),
          ),
        ),
      ],
    );
  }

  // =============== 入口跳转 / 交互 ===============

  /// 编辑资料（顶部「编辑」胶囊、头像、昵称共用）
  ///
  /// 2026-09-14 需求9：由「用户资料展示页 `ProfilePage`」改为**直接进编辑资料页
  /// `EditProfilePage`**。`ProfilePage` 在本仓已无任何引用（它页内的「编辑」也是转跳
  /// `EditProfilePage`），按约定**保留文件不删**，只是本页不再引用。
  Future<void> _openProfile() async {
    // 编辑资料返回后刷新（IndexedStack 常驻后 initState 不再重跑，必须手动刷）
    // 宽屏：右栏打开，await 立即完成（右栏无"关闭"概念）
    await WideLayoutStore.instance
        .openDetail(context, const EditProfilePage(), paneKey: 'profileEdit');
    if (mounted) _load();
  }

  /// 钱包：宽屏右栏 / 窄屏 push；返回后强刷余额（页内可能刚发生收支）
  Future<void> _openWallet() async {
    await WideLayoutStore.instance
        .openDetail(context, const WalletPage(), paneKey: 'wallet');
    if (mounted) _refreshBalance();
  }

  // 靓号商城 / VIP 会员（2026-10-05）：与钱包同款 detail-pane 打开方式；
  // 返回后重拉 profile——购买成功后「VIP 购买/靓号商城」入口要立即消失（2026-10-05 需求）
  Future<void> _openShop() async {
    await WideLayoutStore.instance
        .openDetail(context, ShopPage(), paneKey: 'shop');
    if (mounted) _load();
  }

  Future<void> _openVip() async {
    await WideLayoutStore.instance
        .openDetail(context, VipPage(), paneKey: 'vip');
    if (mounted) _load();
  }

  void _openFavorites() {
    WideLayoutStore.instance
        .openDetail(context, const FavoritesPage(), paneKey: 'favorites');
  }

  void _openAbout() {
    WideLayoutStore.instance
        .openDetail(context, const AboutPage(), paneKey: 'about');
  }

  /// 「系统设置」（2026-09-17 需求：我的收藏下方新增入口）。
  /// 页内收口：账号安全（修改登录密码/支付密码/绑定手机/注销）、AI 翻译、
  /// 群发助手、通知开关、深色模式。该页此前无任何入口（孤儿页），此为唯一入口。
  void _openSystemSettings() {
    WideLayoutStore.instance.openDetail(context, const SystemSettingsPage(),
        paneKey: 'systemSettings');
  }

  /// 「聊天设置」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openChatSettings() {
    WideLayoutStore.instance
        .openDetail(context, const ChatSettingsPage(), paneKey: 'chatSettings');
  }

  /// 「设备」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openDevice() {
    WideLayoutStore.instance
        .openDetail(context, const DevicePage(), paneKey: 'device');
  }

  /// 「通知和声音」（V2 复刻页，2026-09-14 接线；原先是打开 SystemSettingsPage）
  void _openNotifySettings() {
    WideLayoutStore.instance.openDetail(
        context, const NotificationSettingsPage(),
        paneKey: 'notifySettings');
  }

  // =============== 添加好友价格（2026-11-07 需求3：入口移至「隐私」设置页最上方，此处仅保留跳转） ===============

  /// 「数据和存储」（V2 复刻页，2026-09-14 接线；原先只弹「敬请期待」）
  void _openDataStorage() {
    WideLayoutStore.instance
        .openDetail(context, const DataStoragePage(), paneKey: 'dataStorage');
  }

  /// 「隐私」（2026-09-14 需求6）：打开 V2 复刻的**隐私设置页**。
  ///
  /// 原先这里打开的是隐私政策全文（`PolicyPage`）；政策全文仍可从「关于」页
  /// / 登录页 / 注册页三处进入，入口没丢，故本页删掉那条重复引用。
  void _openPrivacySettings() {
    WideLayoutStore.instance
        .openDetail(context, const PrivacySettingsPage(), paneKey: 'privacy');
  }

  /// 「外观」（2026-09-14 需求8）：底部弹出「深色模式 / 浅色模式」选择面板。
  ///
  /// - 当前生效项右侧打勾（`Icons.check` —— 界面统一不用 emoji）；
  /// - 选中即切换主题：数据源是 `AppSettings.dark`，调用 `setDark` 后
  ///   `notifyListeners` 会让 main.dart 的 `ctx.watch<AppSettings>()` 重建整个
  ///   `MaterialApp.theme`；本页再 `setState` 一次，刷新「外观」行右侧的状态文字。
  /// - 面板是新增交互（参考包没有这一屏），尺寸沿用本 App 既有的 `showModalBottomSheet`
  ///   风格（圆角 16、行高 56），不自造设计语言。
  Future<void> _showAppearanceSheet() async {
    final t = AppLocalizations.of(context).t;
    final dark = AppSettings.instance.dark;
    final picked = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 勾选单一数据源：第 4 参是「该选项当前是否被选中」，须按各自
            // 选项判断（深色=dark、浅色=!dark）。之前两行都直接传 dark，
            // 导致深色开启时两行同时打勾、浅色时两行都不勾（用户反馈 bug）。
            _appearanceOption(ctx, t('settingsDarkMode'), true, dark),
            _appearanceOption(ctx, t('settingsLightMode'), false, !dark),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await AppSettings.instance.setDark(picked);
    if (mounted) setState(() {});
  }

  /// 外观面板的单行：标题 + 当前生效项右侧打勾。点一下即回传选中值并关面板。
  Widget _appearanceOption(
      BuildContext ctx, String label, bool value, bool current) {
    final scheme = Theme.of(ctx).colorScheme;
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 20),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 16, color: scheme.onSurface)),
            ),
            if (current)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Icon(Icons.check, size: 22, color: scheme.primary),
              ),
          ],
        ),
      ),
    );
  }

  /// 「完善登录账号」（2026-09-14 需求2）：底部弹出**绑定手机号码**面板。
  ///
  /// 复用公共组件 `BindPhoneSheet`（widgets/bind_phone_sheet.dart，2026-11-02
  /// 从 account_security_page 抽取）：与「账号安全 → 绑定手机号」完全同一套
  /// 接口与 UI，图形验证码展示/必填统一受 `FeatureFlags.captchaOn` 控制
  /// （此前本页复刻的私有 `_BindPhoneSheet` 不受该开关联动，已删除）。
  ///
  /// ⚠️ 客户端**只做采集与展示**：手机号是否可用、短信验证码是否正确，全部由服务端
  /// 判定（本地不落库、不自行判断验证码）—— 账号安全类交互的红线。
  Future<void> _showBindPhoneSheet() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => BindPhoneSheet(
          currentPhone: (_profile?['phone']?.toString() ?? '').trim()),
    );
    // 绑定成功后刷新本页（副标题里的「已绑定手机」文案跟着变）
    if (ok == true && mounted) await _load();
  }

  /// 邀请码整行可点：有码则复制，无码提示联系管理员（行为与原实现一致）
  void _copyInviteCode() {
    final t = AppLocalizations.of(context).t;
    if (_inviteCode.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _inviteCode));
      AppDialogs.toast(context, t('meCopied'));
    } else {
      AppDialogs.toast(context, t('meInviteCodeToast'));
    }
  }

  /// 全民邀请码模式：跳「邀请推广中心」二级页（2026-11-11 需求1）
  void _openInvitePromotion() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const InvitePromotionPage()),
    );
  }

  /// 复制 ID（原资料卡片上的复制按钮改挂在副标题行上）
  void _copyId(String shortId, String account) {
    final t = AppLocalizations.of(context).t;
    final v = shortId.isNotEmpty ? shortId : account;
    if (v.isEmpty) return;
    Clipboard.setData(ClipboardData(text: v));
    AppDialogs.toast(context, t('meCopied'));
  }

  /// 本 App 暂未实现的入口：给明确反馈，不做「点了没反应」的死行
  void _comingSoon(String label) {
    AppDialogs.toast(context,
        AppLocalizations.of(context).t('meComingSoonSuffix', {'name': label}));
  }

  /// 右侧显示当前语言（语言入口已改为弹窗菜单选择）
  String _otherLangLabel(BuildContext context) {
    final loc = AppLocalizations.of(context).locale;
    return AppLocalizations.langNativeName(loc);
  }

  /// 语言选择弹窗（跟随系统 + 四语），实现见 widgets/lang_picker.dart（登录/注册/扫码页共用）
  void _showLangPicker(BuildContext context) => showLangPicker(context);
}
