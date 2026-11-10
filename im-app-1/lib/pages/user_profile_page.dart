import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../services/moment_service.dart';
import '../services/user_cache.dart';
import '../theme/design2026.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/app_net_image.dart';
import '../widgets/brand_loading.dart';
import '../widgets/moment_post_card.dart';
import 'pay_pwd_setup_page.dart';
import '../widgets/pay_pwd_input_sheet.dart';
import 'chat_page.dart';
import 'image_viewer_page.dart';
import 'moments_page.dart';
import 'video_player_page.dart';

/// 用户资料页（2026-11-07 三页新版式，对照设计稿 profile.html）：
/// 顶部封面图 200px（封面上浮白色圆形返回按钮）→ 头像压封面（-46，92px 白描边）
/// → 昵称 22/600 + 性别徽标 → ID + 在线/离线圆点 → 签名块（primary 竖条）
/// → 关系按钮区（好友=发消息 / 非好友=添加好友 + 付费通过 ¥X）→ TA 的朋友圈
/// （与朋友圈页同款帖子卡：头像 34 / 缩进 44，只读 + 自己的帖子可删）。
/// 功能保留：朋友圈 feed 加载、付费添加确认/余额流程、发消息跳转、删帖。
class UserProfilePage extends StatefulWidget {
  final String userId;
  final String? name; // 朋友圈列表带入的昵称/头像，接口慢时先显示
  final String? avatar;
  const UserProfilePage(
      {super.key, required this.userId, this.name, this.avatar});

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  final _momentSvc = MomentService.instance;
  final _convSvc = ConversationService();
  final _friendSvc = FriendService();

  Map<String, dynamic>? _profile; // GET /user/:id（PublicUser + online）
  Map<String, dynamic>? _calc; // paid-add calc（价格/分成/支付方式）
  List<Map<String, dynamic>> _posts = []; // TA 的朋友圈（内嵌 feed）
  bool _loading = true;
  bool _busy = false;

  bool get _isFriend => _calc?['isFriend'] == true;
  double get _price =>
      (num.tryParse('${_calc?['price'] ?? 0}') ?? 0).toDouble();
  double get _balance =>
      (num.tryParse('${_calc?['balance'] ?? 0}') ?? 0).toDouble();
  bool get _alipayEnabled => _calc?['alipayEnabled'] == true;
  bool get _online => _profile?['online'] == true;

  /// 自己的资料页：不显示添加/发消息按钮
  bool get _isMine => widget.userId == (UserCache.myId ?? '');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r =
          await ApiClient.instance.get('/api/v1/user/${widget.userId}');
      final body = r.data;
      if (body is Map && body['code'] == 0) {
        _profile = (body['data'] as Map?)?.cast<String, dynamic>();
      }
    } catch (_) {}
    try {
      _calc = await _momentSvc.paidAddCalc(widget.userId);
    } catch (_) {}
    // 内嵌朋友圈 feed（静默失败不阻断资料页）
    try {
      final data = await _momentSvc.listByUser(widget.userId);
      _posts = ((data['list'] as List<dynamic>?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (_posts.isEmpty) {
        // 2026-11-13 修复（问题9）排查加固：接口成功但列表为空也落日志，
        // 便于区分「请求失败」与「服务端过滤后为空」（过滤 [user_profile]）
        debugPrint('[user_profile] listByUser(${widget.userId}) empty list');
      }
    } catch (e) {
      // 2026-11-13 修复（问题9）排查加固：拉取失败仍静默（不加 UI），但落
      // debugPrint 便于用户侧排查「机器人主页看不到朋友圈」（过滤 [user_profile]）
      debugPrint('[user_profile] listByUser(${widget.userId}) failed: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _name =>
      (_profile?['nickname'] ?? widget.name ?? '').toString();
  String get _avatar =>
      (_profile?['avatar'] ?? widget.avatar ?? '').toString();

  /// 意图+2026-11-07：三页新版式（对照 profile.html）——封面 200px + 头像压
  /// 封面（-46）+ 昵称/性别/ID/在线/签名 + 关系 pill 按钮 + TA 的朋友圈 feed。
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: D2026.bg,
      body: _loading
          ? const Center(child: BrandRingLoader())
          : RefreshIndicator(
              onRefresh: () async => _load(),
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  // 封面 + 压封面的资料块（Transform 上移 46 实现负 margin）
                  Column(
                    children: [
                      _cover(topPad),
                      Transform.translate(
                        offset: const Offset(0, -46),
                        child: _profileBlock(),
                      ),
                    ],
                  ),
                  // TA 的朋友圈（feed-head：4px primary 竖条 + 15/600 标题）
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.only(bottom: 12),
                      decoration: const BoxDecoration(
                        border: Border(
                            bottom: BorderSide(color: D2026.outline2)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 4,
                            height: 15,
                            decoration: BoxDecoration(
                              color: D2026.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(t('userProfileMomentsFeed'),
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: D2026.text1)),
                        ],
                      ),
                    ),
                  ),
                  ..._posts.map(_feedCard),
                  if (_posts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                          child: Text(t('momentsFriendEmpty'),
                              style: const TextStyle(
                                  fontSize: 13, color: D2026.text3))),
                    ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  /// 顶部封面 200px（上浮白色圆形返回按钮，避开状态栏）
  Widget _cover(double topPad) {
    return SizedBox(
      width: double.infinity,
      height: 200 + topPad,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: const Color(0xFFDCEAFE),
            child: Image.asset('assets/images/profile_cover.png',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Container(color: const Color(0xFFDCEAFE))),
          ),
          Positioned(
            top: topPad + 6,
            left: 10,
            child: Material(
              color: Colors.white.withValues(alpha: 0.92),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => Navigator.of(context).maybePop(),
                child: const Padding(
                  padding: EdgeInsets.all(7),
                  child: Icon(Icons.arrow_back_ios_new,
                      size: 18, color: D2026.text1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 资料块：92px 圆头像（4px 白描边 + 卡片阴影，压封面）→ 昵称 + 性别徽标
  /// → ID + 在线圆点 → 签名块 → 关系按钮区
  Widget _profileBlock() {
    final t = AppLocalizations.of(context).t;
    final gender = (_profile?['gender'] ?? 'secret').toString();
    final shortId = (_profile?['shortId'] ?? '').toString();
    final signature = (_profile?['signature'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 92px 圆头像：4px 白描边 + 卡片阴影；无头像时 accent 底 + 首字
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: D2026.surface, width: 4),
              boxShadow: D2026.cardShadow,
            ),
            child: AppAvatar(
                url: _avatar,
                name: _name,
                size: 84,
                radius: 42,
                background: D2026.accent),
          ),
          const SizedBox(height: 16),
          // 昵称 22/600 + 22px 圆形性别徽标（accent-soft 底 accent 色，未知不显示）
          Row(
            children: [
              Flexible(
                child: Text(_name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: D2026.text1)),
              ),
              if (gender == 'male' || gender == 'female') ...[
                const SizedBox(width: 12),
                Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                      shape: BoxShape.circle, color: D2026.accentSoft),
                  child: Icon(gender == 'male' ? Icons.male : Icons.female,
                      size: 14, color: D2026.accent),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // meta 行：ID + 8px 在线圆点（在线带光晕）+ 在线/离线文案
          Row(
            children: [
              Flexible(
                child: Text(
                  shortId.isNotEmpty
                      ? 'ID: $shortId'
                      : 'ID: ${(_profile?['account'] ?? '').toString()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 13, color: D2026.text3),
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _online ? D2026.online : D2026.offline,
                  boxShadow: _online
                      ? [
                          BoxShadow(
                              color: D2026.online.withValues(alpha: 0.35),
                              blurRadius: 6,
                              spreadRadius: 2),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 6),
              Text(_online ? t('chatStatusOnline') : t('chatStatusOffline'),
                  style:
                      const TextStyle(fontSize: 13, color: D2026.text3)),
            ],
          ),
          // 签名块：surface-2 底、左 3px primary 竖条、圆角右 10（无签名不显示）
          // 2026-11-13 修复（问题9 真因）：原 Row(crossAxisAlignment: stretch)
          // 直接放在 ListView 无界高度里——stretch 会给 3px 竖条下发
          // tightFor(height: ∞) 约束（flex.dart _constraintsForNonFlexChild），
          // release 包跳过断言 → 签名块变成无限高的背景色块，资料页按钮/
          // 「TA 的朋友圈」标题/动态全部被推到无穷远 → AI 主页看不到朋友圈、
          // 且页面可以无限拖动全是背景色。IntrinsicHeight 给 Row 一个有界的
          // 内在高度后 stretch 恢复正常（竖条与文字等高）。
          if (signature.isNotEmpty) ...[
            const SizedBox(height: 16),
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 3, color: D2026.primary),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: const BoxDecoration(
                        color: D2026.surface2,
                        borderRadius: BorderRadius.horizontal(
                            right: Radius.circular(D2026.rSm)),
                      ),
                      child: Text(signature,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14,
                              color: D2026.text2,
                              height: 1.6)),
                    ),
                  ),
                ],
              ),
            ),
          ],
          // 关系按钮区（自己的资料页不显示）
          if (!_isMine) ...[
            const SizedBox(height: 20),
            _actionRow(),
          ],
        ],
      ),
    );
  }

  /// 关系按钮区（保留既有关系判断与付费添加逻辑）：
  /// 好友=「发送消息」primary pill；非好友=「添加好友」primary +
  /// 「付费通过 ¥X」暖金（#E8923A）pill（价格为 0 或未设则只显示添加好友）
  Widget _actionRow() {
    final t = AppLocalizations.of(context).t;
    if (_isFriend) {
      return _pillButton(
        label: t('userProfileSendMessage'),
        icon: Icons.chat_bubble_outline,
        color: D2026.primary,
        onTap: _busy ? null : _sendMsg,
      );
    }
    if (_price > 0) {
      return Row(
        children: [
          Expanded(
            child: _pillButton(
              label: t('userProfileAddFriend'),
              icon: Icons.add,
              color: D2026.primary,
              onTap: _busy ? null : _requestFriend,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _pillButton(
              label: t('userProfilePayPass',
                  {'price': _price.toStringAsFixed(0)}),
              icon: Icons.bolt,
              color: D2026.paid,
              onTap: _busy ? null : _showPaySheet,
            ),
          ),
        ],
      );
    }
    return _pillButton(
      label: t('userProfileAddFriend'),
      icon: Icons.add,
      color: D2026.primary,
      onTap: _busy ? null : _requestFriend,
    );
  }

  /// pill 主按钮（高 46、圆角 999、白字 15/600、float 阴影）
  Widget _pillButton({
    required String label,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(999),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// TA 的朋友圈帖子卡（与朋友圈页同款：头像 34 / 缩进 44，只读展示；
  /// 点击整卡进完整朋友圈页；自己的帖子保留删除入口）
  Widget _feedCard(Map<String, dynamic> p) {
    return MomentPostCard(
      post: p,
      avatarSize: 34,
      indent: 44,
      readOnly: true,
      allowDelete: true,
      onCardTap: () => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  MomentsPage(userId: widget.userId, userName: _name))),
      onDelete: (post, postId) => _deletePost(post, postId),
      onOpenImages: (urls, index) => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  ImageViewerPage(urls: urls, initialIndex: index))),
      onOpenVideo: (url) => Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoPlayerPage(url: url))),
    );
  }

  /// 删除自己的朋友圈动态（确认后调服务端删除并本地移除）
  Future<void> _deletePost(Map<String, dynamic> p, String postId) async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('momentsDeletePost'),
        message: t('momentsDeletePostConfirm'),
        danger: true);
    if (ok != true) return;
    try {
      await _momentSvc.deletePost(postId);
      if (!mounted) return;
      setState(() {
        _posts.removeWhere((e) => (e['id'] ?? '').toString() == postId);
      });
    } catch (_) {
      if (mounted) {
        AppDialogs.toast(context, t('momentsActionFailed'));
      }
    }
  }

  /// 普通好友申请（价格=0 的原通道）
  Future<void> _requestFriend() async {
    final t = AppLocalizations.of(context).t;
    final msg = await AppDialogs.input(context,
        title: t('addFriendTitle'),
        hint: t('addFriendMsgHint', {'name': _name}),
        initialValue: t('addFriendDefaultMsg'),
        maxLines: 3,
        maxLength: 100,
        confirmText: t('addFriendSend'));
    if (msg == null) return;
    setState(() => _busy = true);
    final err = await _friendSvc.request(widget.userId, message: msg);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err == null) {
      AppDialogs.toast(context, t('addFriendSent'));
    } else {
      AppDialogs.toast(context, err.isEmpty ? t('addFriendSendFailed') : err);
    }
  }

  /// 好友 → 发消息（friend_detail_page 同款范式）
  Future<void> _sendMsg() async {
    final t = AppLocalizations.of(context).t;
    setState(() => _busy = true);
    try {
      final conv = await _convSvc.createDirect(widget.userId);
      if (!mounted) return;
      final convId = conv['id']?.toString() ?? '';
      final item = ConvItem.fromJson({
        'conversation': {'id': convId},
        'conversationName': _name,
        'peerId': widget.userId,
      });
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ChatPage(conv: item, myId: UserCache.myId ?? '')));
    } catch (e) {
      if (mounted) {
        AppDialogs.toast(
            context, t('friendDetailStartConvFailed', {'error': '$e'}));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 支付方式弹层：余额支付（即时） / 支付宝凭证（后台审核，启用时才显示）
  Future<void> _showPaySheet() async {
    final t = AppLocalizations.of(context).t;
    await showModalBottomSheet(
      context: context,
      backgroundColor: D2026.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                  t('userProfilePayTitle',
                      {'price': _price.toStringAsFixed(2)}),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            // 余额支付
            ListTile(
              leading: const Icon(Icons.account_balance_wallet,
                  color: D2026.online),
              title: Text(t('payMethodBalance')),
              subtitle: Text(t('payMethodBalanceHint',
                  {'balance': _balance.toStringAsFixed(2)})),
              trailing:
                  _balance < _price ? Text(t('payBalanceNotEnough')) : null,
              onTap: _balance < _price ? null : () => _payBalance(ctx),
            ),
            // 支付宝（后台启用了收款码才出现；未启用则只有余额，直接余额扣款）
            if (_alipayEnabled)
              ListTile(
                leading:
                    const Icon(Icons.payment, color: Color(0xFF1677FF)),
                title: Text(t('payMethodAlipay')),
                subtitle: Text(t('payMethodAlipayHint')),
                onTap: () => _payAlipay(ctx),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 余额支付：输支付密码 → 服务端扣款+分成+直接成为好友
  /// 2026-11-07（夜11）：未设置支付密码时不再弹密码输入框（必然校验失败），
  /// 直接跳「设置支付密码」页，设置完返回后刷新报价（拿新 hasPayPwd）。
  Future<void> _payBalance(BuildContext sheetCtx) async {
    Navigator.pop(sheetCtx);
    final t = AppLocalizations.of(context).t;
    if (_calc?['hasPayPwd'] != true) {
      AppDialogs.toast(context, t('userProfileNoPayPwd'));
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const PayPwdSetupPage()));
      if (mounted) _load();
      return;
    }
    final payPwd =
        await PayPwdInputSheet.show(context, title: t('payPwdInputTitle'));
    if (payPwd == null) return;
    setState(() => _busy = true);
    try {
      await _momentSvc.paidAdd(widget.userId, method: 1, payPwd: payPwd);
      if (!mounted) return;
      AppDialogs.toast(context, t('userProfilePaidOk'));
      _load();
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        AppDialogs.toast(context, msg.isEmpty ? t('momentsActionFailed') : msg);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 支付宝：展示收款码 → 用户转账后上传凭证 → 创建待审核订单
  Future<void> _payAlipay(BuildContext sheetCtx) async {
    Navigator.pop(sheetCtx);
    final t = AppLocalizations.of(context).t;
    final qr = (_calc?['alipayQrcodeUrl'] ?? '').toString();
    XFile? proof;
    await showModalBottomSheet(
      context: context,
      backgroundColor: D2026.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  t('userProfileAlipayTitle',
                      {'price': _price.toStringAsFixed(2)}),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 14),
              if (qr.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: AppNetImage(url: qr, width: 200, height: 200),
                ),
              const SizedBox(height: 8),
              Text(t('userProfileAlipayTip'),
                  style: const TextStyle(
                      fontSize: 12, color: D2026.text3)),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () async {
                  final picker = ImagePicker();
                  final f = await picker.pickImage(
                      source: ImageSource.gallery, imageQuality: 85);
                  if (f != null) proof = f;
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.upload_file),
                label: Text(proof == null
                    ? t('userProfileUploadProof')
                    : t('userProfileProofPicked')),
              ),
            ],
          ),
        ),
      ),
    );
    if (proof == null) return;
    setState(() => _busy = true);
    try {
      final url = await ApiClient.instance
          .uploadXFile(proof!, proof!.name, dir: 'friend-add/');
      final urlStr = (url['url'] ?? '').toString();
      await _momentSvc.paidAdd(widget.userId,
          method: 2, proofImage: urlStr);
      if (!mounted) return;
      AppDialogs.toast(context, t('userProfileAlipaySubmitted'));
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        AppDialogs.toast(context, msg.isEmpty ? t('momentsActionFailed') : msg);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
