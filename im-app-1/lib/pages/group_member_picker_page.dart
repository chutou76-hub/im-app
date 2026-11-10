import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';

/// 群转账：选择收款人（单选，返回成员 Map {id, nickname, ...}）
/// 2026-10-07 需求2+3：
///   ② 数据源改为**进页实时拉取**（原由调用方传 State 缓存的 members，新成员进群后
///      要重启 App 才刷新）；带下拉刷新 + 右上角刷新按钮 + 搜索框实时过滤。
///   ③ 返回键改用 V2 统一规格（`arrow_back_ios_new` size 25.2、命中盒 44、
///      ink 左缘 23），与钱包页/聊天窗口一致（选型依据见 wallet_page 常量注释）。
class GroupMemberPickerPage extends StatefulWidget {
  /// 2026-10-07 需求2：改为传会话 id，由本页实时拉成员
  final String convId;
  final String myId;

  /// 兼容旧调用（可选预置成员，实时拉取失败时兜底）
  final List<Map<String, dynamic>>? initialMembers;

  const GroupMemberPickerPage({
    super.key,
    required this.convId,
    required this.myId,
    this.initialMembers,
  });

  @override
  State<GroupMemberPickerPage> createState() => _GroupMemberPickerPageState();
}

class _GroupMemberPickerPageState extends State<GroupMemberPickerPage> {
  /// V2 统一返回键规格（与 wallet_page 一致）
  static const double _kBackSize = 25.2;
  static const double _kBackHit = 44.0;
  static const double _kBackLeft = 23.0;

  final _svc = ConversationService();
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _members = [];
  bool _loading = true;
  String _loadError = '';
  String _q = '';

  @override
  void initState() {
    super.initState();
    _members = List.of(widget.initialMembers ?? const []);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 2026-10-07 需求2：进页实时拉取（保证新成员立刻可见）
  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = '';
      });
    }
    try {
      final list = await _svc.members(widget.convId);
      if (!mounted) return;
      setState(() {
        _members = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '$e';
      });
    }
  }

  /// 昵称 / 短ID / 账号 / 备注 任一命中即保留（大小写不敏感）
  bool _match(Map<String, dynamic> m) {
    if (_q.isEmpty) return true;
    final k = _q.toLowerCase();
    final name = (m['nickname'] ?? m['name'] ?? '').toString().toLowerCase();
    final shortId = (m['shortId'] ?? '').toString().toLowerCase();
    final account = (m['account'] ?? '').toString().toLowerCase();
    final remark = (m['remark'] ?? '').toString().toLowerCase();
    return name.contains(k) ||
        shortId.contains(k) ||
        account.contains(k) ||
        remark.contains(k);
  }

  /// V2 统一返回键（2026-10-07 需求3）
  Widget _backButton() {
    return SizedBox(
      width: _kBackLeft + _kBackHit,
      height: _kBackHit,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: _kBackHit,
          height: _kBackHit,
          child: InkWell(
            onTap: () => Navigator.of(context).maybePop(),
            customBorder: const CircleBorder(),
            child: Center(
              child: Icon(Icons.arrow_back_ios_new,
                  size: _kBackSize, color: context.cs.onSurface),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final selectable = _members
        .where((m) => (m['id']?.toString() ?? '') != widget.myId)
        .where(_match)
        .toList();
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        automaticallyImplyLeading: false,
        leadingWidth: _kBackLeft + _kBackHit,
        leading: _backButton(),
        titleSpacing: 0,
        title: Text(t('memberPickerTitle'),
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: context.cs.onSurface)),
        actions: [
          // 需求2：手动刷新（成员变动后可立即同步）
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: t('memberPickerRefresh'),
          ),
        ],
      ),
      body: Column(
        children: [
          // 2026-10-07 需求3：搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _q = v.trim()),
              style: const TextStyle(fontSize: 15),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: t('memberPickerSearchHint'),
                hintStyle:
                    TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
                prefixIcon: Icon(Icons.search,
                    size: 18, color: context.cs.onSurfaceVariant),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 32),
                suffixIcon: _q.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _q = '');
                        },
                      ),
                filled: true,
                fillColor: context.cs.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading && _members.isEmpty
                ? Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primary),
                  )
                : selectable.isEmpty
                    ? Center(
                        child: Text(
                          _loadError.isNotEmpty
                              ? t('memberPickerLoadFail')
                              : (_q.isEmpty
                                  ? t('memberPickerEmpty')
                                  : t('memberPickerNoResult')),
                          style: TextStyle(
                              fontSize: 13, color: context.cs.onSurfaceVariant),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _load,
                        color: AppTheme.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          itemCount: selectable.length,
                          itemBuilder: (ctx, i) {
                            final m = selectable[i];
                            final id = m['id']?.toString() ?? '';
                            final name = (m['nickname'] ??
                                    m['name'] ??
                                    t('memberPickerMember'))
                                .toString();
                            final avatar = (m['avatar'] ?? '').toString();
                            return InkWell(
                              onTap: () => Navigator.pop(context, m),
                              borderRadius:
                                  BorderRadius.circular(AppTheme.radiusMd),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 10),
                                margin: const EdgeInsets.only(bottom: 8),
                                decoration: BoxDecoration(
                                  color: context.cs.surface,
                                  borderRadius:
                                      BorderRadius.circular(AppTheme.radiusMd),
                                ),
                                child: Row(
                                  children: [
                                    // 有头像显示真实头像，加载中/失败/无头像都回落首字母占位
                                    AppAvatar(
                                      url: avatar,
                                      name: name,
                                      size: 42,
                                      background: AppTheme.avatarColors[id
                                          .hashCode
                                          .abs() %
                                          AppTheme.avatarColors.length],
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(name,
                                              style: TextStyle(
                                                  fontSize: 15,
                                                  color: context.cs.onSurface)),
                                          // 有短ID/账号 时副行展示，便于按 ID 找人
                                          if ((m['shortId'] ?? '')
                                                  .toString()
                                                  .isNotEmpty ||
                                              (m['account'] ?? '')
                                                  .toString()
                                                  .isNotEmpty)
                                            Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 2),
                                              child: Text(
                                                [
                                                  if ((m['shortId'] ?? '')
                                                          .toString()
                                                          .isNotEmpty)
                                                    'ID: ${m['shortId']}',
                                                  if ((m['account'] ?? '')
                                                          .toString()
                                                          .isNotEmpty)
                                                    (m['account'] ?? '')
                                                        .toString(),
                                                ].join(' · '),
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: context
                                                        .cs.onSurfaceVariant),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right,
                                        size: 18,
                                        color: context.cs.onSurfaceVariant),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}