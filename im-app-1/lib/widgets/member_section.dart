import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../l10n/app_locale.dart';
import '../pages/user_qr_profile_page.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart'; // v2IsDark（深色模式判定）
import '../widgets/app_avatar.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart'; // V2SetCard / context.setXxx

/// 成员/订阅者区（2026-10-08 抽公共组件）。
///
/// 原先这套 UI 只存在于 `GroupManagePage`（群管理页）内部，频道资料页要用就得
/// 复制 250 行 + 12 个私有常量，故抽成组件供两处共用：
///   - 群聊：`成员 N 🔍` + 竖排成员行（点击弹管理面板/ 看资料）
///   - 频道：`订阅者 N 🔍` + 竖排订阅者行（称谓不同，数据源同一 `members()` 接口）
///
/// 频道 = `conversation type=3`，与群共用同一张表与同一批端点，故**数据源相同**，
/// 差异仅在[memberNoun]（成员/订阅者）等称谓。
///
/// 对应 UI（实测稿）：行高 77.1、头像 51（圆角 9.3）、昵称 21.7、在线/离线 16.2、
/// 群主昵称绿 #66C7A3、右侧 chevron；标题左侧 41.7，人数字号 17，放大镜 22。
class MemberSection extends StatefulWidget {
  final ConvItem conv;

  /// 称谓：群=「成员」，频道=「订阅者」（标题文案走 chatMember / channelSubscribers）
  final bool isChannel;

  /// 点击成员行：群主/管理员弹管理面板（由宿主实现）；传null 则直接看资料
  final void Function(Map<String, dynamic> member)? onMemberTap;

  /// 是否可管理（群主/管理员）：决定成员行点击行为与「加载更多」是否可用
  final bool canManage;

  /// 行点击是否可跳转资料页。**频道传 false**（2026-10-08 用户要求：
  /// 订阅者行不跳转）；群聊传 true（保持原行为）。
  final bool tappable;

  /// 2026-10-09：标题右侧的“数量”改为 **+ 号邀请入口**。
  /// - [null] = 保持原行为（只显示数量）；本项为 null 时不渲染 + 号。
  /// - 非 null 时显示可点的 + 号（可点籉b会交给该回调）。
  /// 调用方应自行判断是否允许邀请（如群设置 allowMemberInvite）。
  final VoidCallback? onInviteTap;

  const MemberSection({
    super.key,
    required this.conv,
    this.onInviteTap,
    this.isChannel = false,
    this.onMemberTap,
    this.canManage = false,
    this.tappable = true,
  });

  @override
  State<MemberSection> createState() => _MemberSectionState();
}

class _MemberSectionState extends State<MemberSection> {
  final _svc = ConversationService();

  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  bool _loadingMore = false;
  int _memberTotal = 0;

  /// 分页大小（同群管理页：只拉首屏 20 个，管理角色按 role 排最前不受影响）
  static const int _kPageSize = 20;

  String get _convId => widget.conv.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await _svc.members(_convId, page: 1, size: _kPageSize);
      if (!mounted) return;
      setState(() {
        _members = m;
        if (_svc.lastMembersCount > 0) _memberTotal = _svc.lastMembersCount;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _uidOf(Map<String, dynamic> m) =>
      m['id']?.toString() ?? m['userId']?.toString() ?? '';

  /// 显示名：群昵称 > 好友备注 > 用户昵称 > 账号（与群管理页同一口径）
  String _nameOf(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final groupNick = m['groupNickname']?.toString().trim() ?? '';
    final remark = m['remark']?.toString() ?? '';
    final realName = (m['nickname']?.toString().trim().isNotEmpty ?? false)
        ? m['nickname'].toString()
        : (m['account']?.toString() ?? t('contactsUser'));
    return groupNick.isNotEmpty
        ? groupNick
        : (remark.isNotEmpty ? remark : realName);
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _members.length >= _memberTotal) return;
    setState(() => _loadingMore = true);
    try {
      final next = await _svc.members(_convId,
          page: _members.length ~/ _kPageSize + 1, size: _kPageSize);
      if (!mounted) return;
      setState(() {
        final seen = _members.map(_uidOf).toSet();
        for (final it in next) {
          if (seen.add(_uidOf(it))) _members.add(it);
        }
      });
    } catch (_) {
      // 静默失败：保留已加载内容，用户可再次点按重试
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // 注：原有个 _openMembers()（跳 GroupMembersPage）随2026-10-08「去掉搜索图标」
  // 一并移除，故不再 import group_members_page.dart。

  void _onTapRow(Map<String, dynamic> m) {
    final cb = widget.onMemberTap;
    if (widget.canManage && cb != null) {
      cb(m);
      return;
    }
    // 2026-10-08（用户要求）：**订阅者行不跳转任何页面**。
    // 频道订阅者未必是好友（可能只是关注了频道），跳好友资料页语义不对，
    // 而项目暂无「任意非好友用户资料页」，故此处不跳。
    // 若[widget.tappable] 为 true（群聊场景），仍按原逻辑进资料页。
    if (!widget.tappable) return;
    final uid = _uidOf(m);
    if (uid.isEmpty) return;
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserQrProfilePage(uid: uid)));
  }

  // ============================== UI ==============================

  /// 分区标题：「成员/订阅者  N」
  /// 2026-10-08（用户要求）：去掉右侧放大镜搜索图标（此前跳 GroupMembersPage），
  /// 频道订阅者区不需要搜索入口。
  Widget _header(double s) {
    final t = AppLocalizations.of(context).t;
    final label =
        widget.isChannel ? t('channelSubscribersNoun') : t('chatMember');
    return Padding(
      padding: EdgeInsets.only(left: _kSecTitleLeft * s, right: 15.9 * s),
      child: SizedBox(
        height: _kSecIconSize * s,
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: _kSecTitleSize * s,
                    height: 1.0,
                    color: context.setLabel)),
            const Spacer(),
            // 2026-10-09：有邀请入口时，右侧故隐数量改为可点的 + 号；
            // 数量信息由成员行里的信息承担，不再在标题重复。
            if (widget.onInviteTap != null)
              InkWell(
                onTap: widget.onInviteTap,
                borderRadius: BorderRadius.circular(20 * s),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: 10 * s, vertical: 4 * s),
                  child: Icon(Icons.add,
                      size: _kSecIconSize * s, color: context.setLabel),
                ),
              )
            else
              Text(
                _loading ? '' : '${_members.length}',
                style: TextStyle(
                    fontSize: _kSecCountSize * s,
                    height: 1.0,
                    color: _numColor(context)),
              ),
          ],
        ),
      ),
    );
  }

  /// 成员卡：逐行竖排 + 未拉全时的「加载更多」
  Widget _card(double s) {
    if (_loading) {
      return const V2SetCard(rows: [SizedBox(height: 120)]);
    }
    if (_members.isEmpty) {
      final t = AppLocalizations.of(context).t;
      return V2SetCard(rows: [
        SizedBox(
          height: _kMemRowH * s,
          child: Center(
            child: Text(
              widget.isChannel ? t('channelSubscribersEmpty') : t('convSetNoMembers'),
              style: TextStyle(fontSize: _kMemSubSize * s, color: context.setSub),
            ),
          ),
        ),
      ]);
    }
    return V2SetCard(rows: [
      for (final m in _members) _row(s, m),
      if (_members.length < _memberTotal) _loadMoreRow(s),
    ]);
  }

  /// 「加载更多成员」行：已加载/总数
  Widget _loadMoreRow(double s) {
    final t = AppLocalizations.of(context).t;
    return SizedBox(
      height: _kMemRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _loadingMore ? null : _loadMore,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_loadingMore) ...[
                SizedBox(
                    width: 14 * s,
                    height: 14 * s,
                    child: const CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8 * s),
              ],
              Text(
                // ⚠️ 修 bug（2026-10-08）：原写 `($_members.length/$_memberTotal)`，
                // Dart 里 `$` 后紧跟 `_` 会被当成标识符 `$_members`（不存在），
                // 渲染成 `([{id: ...` 整段对象 toString。必须用 `${...}` 显式包边界。
                '${t('loadMoreMembers')} (${_members.length}/$_memberTotal)',
                style:
                    TextStyle(fontSize: _kMemSubSize * s, color: context.setSub),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 成员行：头像 + 昵称(+角色徽章) + 在线/离线 + 右箭头
  Widget _row(double s, Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final name = _nameOf(m);
    final role = (m['role'] as num?)?.toInt() ?? 3;
    final isOwner = role == 1;
    final isAdmin = role == 2;

    return SizedBox(
      height: _kMemRowH * s,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _onTapRow(m),
          child: Row(
            children: [
              SizedBox(width: _kMemAvatarLeft * s),
              AppAvatar(
                url: AppConfig.assetUrl(m['avatar']?.toString() ?? ''),
                name: name,
                size: _kMemAvatarD * s,
                radius: _kMemAvatarR * s,
              ),
              SizedBox(
                  width: (_kMemTextLeft - _kMemAvatarLeft - _kMemAvatarD) * s),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: _kMemNameSize * s,
                              height: 1.0,
                              // 群主/频道主昵称绿色（实测 #66C7A3），其余近黑
                              color: isOwner
                                  ? _ownerNameColor(context)
                                  : context.setTitle,
                            ),
                          ),
                        ),
                        if (isOwner || isAdmin) ...[
                          SizedBox(width: 8.7 * s),
                          _roleTag(s,
                              isOwner ? 'gmpRoleCreator' : 'groupRoleAdmin',
                              isOwner),
                        ],
                      ],
                    ),
                    SizedBox(height: 10.7 * s),
                    Text(
                      (m['online'] == true)
                          ? t('chatStatusOnline')
                          : t('convSetOffline'),
                      style: TextStyle(
                          fontSize: _kMemSubSize * s,
                          height: 1.0,
                          color: _offlineColor(context)),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.only(right: _kChevronRight * s),
                child: Icon(Icons.chevron_right,
                    size: 24 * s, color: context.setChevron),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 角色徽章：创建者 = 灰底近黑字；管理员 = 浅绿底绿字（实测稿取值）
  Widget _roleTag(double s, String labelKey, bool owner) {
    return Container(
      height: _kTagH * s,
      padding: EdgeInsets.symmetric(horizontal: _kTagPadX * s),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: owner ? _ownerTagBg(context) : _adminTagBg(context),
        borderRadius: BorderRadius.circular(_kTagR * s),
      ),
      child: Text(
        AppLocalizations.of(context).t(labelKey),
        style: TextStyle(
          fontSize: _kTagSize * s,
          height: 1.0,
          color: owner ? _ownerTagFg(context) : _adminTagFg(context),
        ),
      ),
    );
  }

  /// 对外暴露：供宿主刷新（如从成员页返回）
  void reload() => _load();

  @override
  Widget build(BuildContext context) {
    final s = v2Scale(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(s),
        SizedBox(height: _kSecBottom * s),
        _card(s),
      ],
    );
  }
}

// ============================== 尺寸/颜色常量 ==============================
// 取自实测稿（与 group_manage_page.dart 原定义一致，勿随意改动）

const double _kSecTitleLeft = 41.7;
const double _kSecTitleSize = 15.9;
const double _kSecCountSize = 17.0;
const double _kSecIconSize = 22.0;
const double _kSecBottom = 23.4;

const double _kMemRowH = 77.1;
const double _kMemAvatarD = 51.0;
const double _kMemAvatarR = 9.3;
const double _kMemAvatarLeft = 20.6;
const double _kMemTextLeft = 88.0; // 昵称 ink 左 108.7 - 卡左 20.7
const double _kMemNameSize = 21.7;
const double _kMemSubSize = 16.2;

const double _kTagH = 23.0;
const double _kTagR = 5.0;
const double _kTagSize = 13.5;
const double _kTagPadX = 8.0;

const double _kChevronRight = 21.75; // 使 chevron ink 中心落在 365.2

const Color _kOwnerName = Color(0xFF66C7A3); // 群主昵称绿（实测 #66C7A3/#69C7A3）
const Color _kOwnerTagBg = Color(0xFFE9E9EB);
const Color _kOwnerTagFg = Color(0xFF141517);
const Color _kAdminTagBg = Color(0xFFE5F3E6);
const Color _kAdminTagFg = Color(0xFF559857);
const Color _kOffline = Color(0xFF9B9B9B);
const Color _kNumColor = Color(0xFF989EA7);

Color _ownerNameColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF5FC79B) : _kOwnerName;
Color _ownerTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF3A3A3C) : _kOwnerTagBg;
Color _ownerTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFFF2F2F7) : _kOwnerTagFg;
Color _adminTagBg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF1F3A22) : _kAdminTagBg;
Color _adminTagFg(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF6ECB74) : _kAdminTagFg;
Color _offlineColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kOffline;
Color _numColor(BuildContext c) =>
    c.v2IsDark ? const Color(0xFF8E8E93) : _kNumColor;
