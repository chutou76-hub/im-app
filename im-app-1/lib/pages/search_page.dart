import '../widgets/app_back_button.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/conversation_service.dart';
import '../services/local_store.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart'; // AppDialogs.toast（成员列表加载失败提示）
import '../widgets/member_picker_sheet.dart'; // 2026-10-08：群成员选择面板

/// 消息搜索（全局，仅自己参与的会话）。
/// 2026-09-29 会话内搜索：[convId]/[convName] 非空时只搜该会话的聊天记录
///（chat_page「…」菜单 / 群资料页入口），结果行显示发送人昵称+头像，
/// 点击 pop(该消息 msgId) 由聊天页原地跳转定位（不重开会话）。
class SearchPage extends StatefulWidget {
  const SearchPage(
      {super.key,
      this.initialKeyword,
      this.convId,
      this.convName,
      this.convType});

  /// 搜索模式（消息列表顶栏，十七批）带词跳入：预填并自动执行一次搜索
  final String? initialKeyword;

  /// 会话内搜索范围（2026-09-29）：非空 = 只搜该会话
  final String? convId;

  /// 会话内搜索的会话名（提示条展示用）
  final String? convName;

  /// 会话类型（2026-10-08）：2=群 3=频道。用于决定筛选条是否显示「成员」维度
  /// （私聊无成员概念，隐藏该按钮）。
  final int? convType;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _svc = ConversationService();
  final _ctrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];

  /// 本地搜索历史（最新的在前，落盘保存；退出登录时清空）
  List<String> _history = [];
  int _total = 0;
  bool _searched = false;
  bool _loading = false;

  // ===== 2026-10-08 三维度筛选（微信式筛选条）=====
  /// 按群成员筛选：[_fSenderId] 选中成员 ID（列表高亮 + 发给服务端），
  /// [_fSender] 其昵称（筛选条上显示）
  String _fSender = '';
  String _fSenderId = '';
  /// 日期区间（yyyy-MM-dd，空=不限）
  String _fDateFrom = '';
  String _fDateTo = '';
  /// 消息类型（0=不限）
  int _fMsgType = 0;

  bool get _scoped => (widget.convId ?? '').isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // 搜索模式带词跳入（十七批）：预填关键词并自动搜一次
    final kw = widget.initialKeyword?.trim() ?? '';
    if (kw.isNotEmpty) {
      _ctrl.text = kw;
      _search();
    }
  }

  Future<void> _loadHistory() async {
    try {
      final list = await LocalStore.loadSearchHistory();
      if (mounted) setState(() => _history = list);
    } catch (_) {}
  }

  Future<void> _clearHistory() async {
    await LocalStore.clearSearchHistory();
    if (mounted) setState(() => _history = []);
  }

  // ===== 2026-10-08 三维度筛选 =====
  //
  // 微信式：筛选条上三个胶囊按钮（成员/日期/类型），点击弹底部面板选择，
  // 确认后自动重搜。已选中的维度显示为「填充态 + 前缀文案」（如「类型:图片」），
  // 未选中为描边态。

  /// 筛选值变化后重搜。
  /// 2026-10-10 需求2：选完成员/日期/类型**立即出结果**——不再要求先输关键词，
  /// 无关键词但有任一筛选条件也直接搜（后端已支持纯筛选模式）；
  /// 关键词与筛选都为空才不发请求。
  void _applyFilter() => _search();

  /// 是否设置了任一筛选条件（成员/日期/类型）
  bool get _hasFilter =>
      _fSenderId.isNotEmpty ||
      _fSender.isNotEmpty ||
      _fDateFrom.isNotEmpty ||
      _fDateTo.isNotEmpty ||
      _fMsgType > 0;

  /// yyyy-MM-dd
  String _fmtDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 当前会话是否群/频道（决定「成员」按钮显隐；私聊无成员概念）
  bool get _isGroupOrChannel {
    final ty = widget.convType ?? 0;
    return ty == 2 || ty == 3;
  }

  /// 「成员」筛选：从**群成员列表里选一个**（2026-10-08 用户纠正）。
  ///
  /// 原实现让用户手输昵称再由服务端 LIKE 匹配 —— 那不是「选择成员」，
  /// 且昵称 LIKE 会误伤（群昵称与 users.nickname 不一致、同名互相包含）。
  /// 现改为：拉 `members(convId)` 列出成员，点选即筛出**该成员**的消息。
  /// 选中项回传 `{id, nickname}`，走服务端 `senderId` 精确筛选。
  Future<void> _pickSender() async {
    final t = AppLocalizations.of(context).t;
    final convId = widget.convId;
    if (convId == null || convId.isEmpty) return;

    List<Map<String, dynamic>> members = [];
    try {
      members = await _svc.members(convId, page: 1, size: 200);
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('searchFilterMemberLoadFailed'));
      return;
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: context.cs.surface,
      isScrollControlled: true,
      builder: (ctx) => MemberPickerSheet(
        members: members,
        selectedId: _fSenderId,
        isChannel: (widget.convType ?? 0) == 3,
      ),
    );
    if (picked == null) {
      // 关闭时若已有选中，视为「取消筛选」
      if (mounted && _fSenderId.isNotEmpty) {
        setState(() {
          _fSenderId = '';
          _fSender = '';
        });
        _applyFilter();
      }
      return;
    }
    if (mounted) {
      setState(() {
        _fSenderId = '${picked['id'] ?? ''}';
        _fSender = '${picked['nickname'] ?? ''}';
      });
      _applyFilter();
    }
  }

  /// 「日期」筛选：起止各一天（yyyy-MM-dd，空=不限）
  Future<void> _pickDate() async {
    final t = AppLocalizations.of(context).t;
    DateTime? from = _fDateFrom.isEmpty ? null : DateTime.tryParse(_fDateFrom);
    DateTime? to = _fDateTo.isEmpty ? null : DateTime.tryParse(_fDateTo);
    final res = await showModalBottomSheet<List<DateTime?>>(
      context: context,
      backgroundColor: context.cs.surface,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('searchFilterByDate'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t('searchFilterDateFrom')),
                trailing: Text(
                  from == null
                      ? t('searchFilterUnlimited')
                      : _fmtDate(from!),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
                onTap: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: from ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now());
                  if (d != null) setSheet(() => from = d);
                },
              ),
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t('searchFilterDateTo')),
                trailing: Text(
                  to == null ? t('searchFilterUnlimited') : _fmtDate(to!),
                  style: TextStyle(color: context.cs.onSurfaceVariant),
                ),
                onTap: () async {
                  final d = await showDatePicker(
                      context: ctx,
                      initialDate: to ?? DateTime.now(),
                      firstDate: DateTime(2020),
                      lastDate: DateTime.now());
                  if (d != null) setSheet(() => to = d);
                },
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.pop(ctx, <DateTime?>[null, null]),
                      child: Text(t('searchFilterClear')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, [from, to]),
                      child: Text(t('searchFilterConfirm')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (res == null) return;
    if (mounted) {
      setState(() {
        _fDateFrom = res[0] == null ? '' : _fmtDate(res[0]!);
        _fDateTo = res[1] == null ? '' : _fmtDate(res[1]!);
      });
      _applyFilter();
    }
  }

  /// 「类型」筛选：单选消息类型（0=不限）
  Future<void> _pickType() async {
    final t = AppLocalizations.of(context).t;
    const typeKeys = <int, String>{
      0: 'searchTypeAll',
      2: 'searchTypeImage',
      3: 'searchTypeFile',
      4: 'searchTypeVoice',
      5: 'searchTypeVideo',
      8: 'searchTypeRedPacket',
      9: 'searchTypeTransfer',
      10: 'searchTypeCard',
      11: 'searchTypeLink',
      12: 'searchTypeMerge',
      14: 'searchTypeLocation',
    };
    final res = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: context.cs.surface,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in typeKeys.entries)
                RadioListTile<int>(
                  value: e.key,
                  // ignore: deprecated_member_use
                  groupValue: _fMsgType,
                  // ignore: deprecated_member_use
                  onChanged: (v) => Navigator.pop(ctx, v ?? 0),
                  title: Text(t(typeKeys[e.key] ?? 'searchTypeAll')),
                  dense: true,
                ),
            ],
          ),
        ),
      ),
    );
    if (res == null) return;
    if (mounted) {
      setState(() => _fMsgType = res);
      _applyFilter();
    }
  }

  /// 当前类型维度对应的词条 key（筛选条上显示前缀文案，如「类型:图片」）
  String get _fTypeLabelKey {
    switch (_fMsgType) {
      case 2:
        return 'searchTypeImage';
      case 3:
        return 'searchTypeFile';
      case 4:
        return 'searchTypeVoice';
      case 5:
        return 'searchTypeVideo';
      case 8:
        return 'searchTypeRedPacket';
      case 9:
        return 'searchTypeTransfer';
      case 10:
        return 'searchTypeCard';
      case 11:
        return 'searchTypeLink';
      case 12:
        return 'searchTypeMerge';
      case 14:
        return 'searchTypeLocation';
      default:
        return 'searchTypeAll';
    }
  }

  // ===== 2026-10-08 微信式筛选条 =====
  /// 三个胶囊按钮：成员（仅群/频道）/ 日期 / 类型。已生效维度为「填充态+前缀」。
  /// [t] 是取词条函数（不是已取好的字符串）——内部多处要按维度动态取。
  Widget _filterBar(String Function(String, [Map<String, String>?]) t) {
    final chips = <Widget>[];
    // 成员维度：私聊无成员概念 → 隐藏（用户要求）
    if (_isGroupOrChannel) {
      chips.add(_chip(
        active: _fSenderId.isNotEmpty,
        icon: Icons.people_alt_outlined,
        label: _fSenderId.isNotEmpty
            ? '${t('searchFilterMember')}:$_fSender'
            : t('searchFilterMember'),
        onTap: _pickSender,
      ));
    }
    final dateActive = _fDateFrom.isNotEmpty || _fDateTo.isNotEmpty;
    chips.add(_chip(
      active: dateActive,
      icon: Icons.calendar_today_outlined,
      label: dateActive
          ? '${t('searchFilterDate')}:'
              '${_fDateFrom.isEmpty ? '…' : _fDateFrom}~'
              '${_fDateTo.isEmpty ? '…' : _fDateTo}'
          : t('searchFilterDate'),
      onTap: _pickDate,
    ));
    chips.add(_chip(
      active: _fMsgType > 0,
      icon: Icons.filter_alt_outlined,
      label: _fMsgType > 0
          ? '${t('searchFilterType')}:${t(_fTypeLabelKey)}'
          : t('searchFilterType'),
      onTap: _pickType,
    ));

    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            chips[i],
          ],
        ],
      ),
    );
  }

  /// 单个筛选胶囊
  Widget _chip({
    required bool active,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Center(
      child: Material(
        color: active
            ? AppTheme.primary.withValues(alpha: 0.12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active ? AppTheme.primary : context.cs.outlineVariant,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 14,
                    color: active
                        ? AppTheme.primary
                        : context.cs.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        color: active
                            ? AppTheme.primary
                            : context.cs.onSurface)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _search() async {
    final kw = _ctrl.text.trim();
    // 2026-10-10 需求2：无关键词但有筛选条件也放行（纯筛选模式，后端已支持）
    if (kw.isEmpty && !_hasFilter) return;
    // 记录搜索历史（去重、最新在前、最多 10 条），下次进页还在。
    // 会话内搜索不写历史：范围局部，历史条目在全局搜索页会误导；
    // 纯筛选搜索（无关键词）也不写历史——历史存的是关键词，没有词可存
    if (!_scoped && kw.isNotEmpty) unawaited(LocalStore.addSearchHistory(kw));
    setState(() {
      _loading = true;
      _searched = true;
    });
    try {
      final data = await _svc.searchMessages(kw,
          convId: _scoped ? widget.convId : null,
          // 2026-10-08：三维度筛选（任一变化都重新请求，服务端过滤）
          // 成员筛选走 senderId 精确匹配（昵称 LIKE 会误伤同名/群昵称不同的用户）
          senderId: _fSenderId,
          senderName: _fSenderId.isEmpty ? _fSender : null,
          dateFrom: _fDateFrom,
          dateTo: _fDateTo,
          msgType: _fMsgType);
      if (mounted) {
        setState(() {
          _results = (data['list'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
          _total = (data['total'] as num?)?.toInt() ?? 0;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 结果卡片的预览文案。
  ///
  /// 2026-10-08 修：原实现只给 2/3/4/5 加了类型前缀，其余直接 `content.toString()`，
  /// 而 8 红包 / 9 转账 / 10 名片 / 11 链接 / 12 聊天记录 / 14 位置的 content 都是
  /// **JSON 字符串** → 搜索结果里会显示一整串 `{"kind":"redpacket",...}`（用户反馈）。
  /// 现改为：所有非文本类型一律显示方括号标签，不透出 JSON。
  String _preview(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final type = (m['type'] as num?)?.toInt() ?? 1;
    const labels = <int, String>{
      2: 'searchImage',
      3: 'searchFile',
      4: 'searchVoice',
      5: 'searchVideo',
      6: 'searchTypeSystem',
      7: 'searchTypeCall',
      8: 'searchTypeRedPacket',
      9: 'searchTypeTransfer',
      10: 'searchTypeCard',
      11: 'searchTypeLink',
      12: 'searchTypeMerge',
      13: 'searchTypeTransferReceipt',
      14: 'searchTypeLocation',
    };
    final lb = labels[type];
    if (lb != null) return '[${t(lb)}]';
    // 文本消息（type=1）：直接显示内容；其余未知类型兜底，绝不打印 JSON
    if (type == 1) return m['content']?.toString() ?? '';
    return '[${t('searchTypeUnknown')}]';
  }

  /// 发送人昵称：优先服务端补的 senderNickname，回落账号/占位
  String _senderName(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final n = m['senderNickname']?.toString() ?? '';
    if (n.isNotEmpty) return n;
    final a = m['account']?.toString() ?? '';
    return a.isNotEmpty ? a : t('newConvUser');
  }

  /// 还没搜索时：有历史就展示历史（点一下直接搜），没有才显示引导文案
  Widget _buildHistoryOrTip() {
    final t = AppLocalizations.of(context).t;
    if (_history.isEmpty) {
      return Center(
          child: Text(t('searchEmptyTip'),
              style: TextStyle(color: context.cs.onSurfaceVariant)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 4),
          child: Row(
            children: [
              Text(t('searchHistory'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurfaceVariant)),
              const Spacer(),
              TextButton(
                onPressed: _clearHistory,
                child: Text(t('searchClearHistory'),
                    style:
                        const TextStyle(fontSize: 13, color: AppTheme.primary)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: _history.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: context.cs.outlineVariant),
            itemBuilder: (_, i) {
              final kw = _history[i];
              return ListTile(
                dense: true,
                leading: Icon(Icons.history,
                    size: 18, color: context.cs.onSurfaceVariant),
                title: Text(kw,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 14, color: context.cs.onSurface)),
                onTap: () {
                  _ctrl.text = kw;
                  _ctrl.selection = TextSelection.fromPosition(
                      TextPosition(offset: kw.length));
                  _search();
                },
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: const AppBackButton(),
        titleSpacing: 12,
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          style: TextStyle(fontSize: 15, color: context.cs.onSurface),
          decoration: InputDecoration(
            hintText: _scoped
                ? (widget.convName ?? '').isEmpty
                    ? t('searchHint')
                    : t('searchInConv', {'name': widget.convName!})
                : t('searchHint'),
            hintStyle:
                TextStyle(fontSize: 15, color: context.cs.onSurfaceVariant),
            isDense: true,
            filled: true,
            fillColor: context.cs.surfaceContainer,
            prefixIcon: Icon(Icons.search,
                size: 20, color: context.cs.onSurfaceVariant),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              borderSide: BorderSide.none,
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
        ),
        actions: [
          TextButton(
              onPressed: _search,
              child: Text(t('searchAction'),
                  style: const TextStyle(color: AppTheme.primary))),
        ],
      ),
      // 2026-10-08：筛选条常驻在搜索框下方（微信式），与结果区上下排列
      body: Column(
        children: [
          _filterBar(t),
          Expanded(
            child: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_searched
              ? _buildHistoryOrTip()
              : _results.isEmpty
                  ? Center(
                      child: Text(t('searchNoResults'),
                          style:
                              TextStyle(color: context.cs.onSurfaceVariant)))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                          child: Text(
                              t('searchResultCount', {'count': '$_total'}),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: context.cs.onSurfaceVariant)),
                        ),
                        Expanded(
                          child: ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _results.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 10),
                            itemBuilder: (_, i) {
                              final m = _results[i];
                              final msgId =
                                  m['msgId']?.toString().replaceAll('"', '');
                              return InkWell(
                                // 2026-09-29 会话内搜索：点击回传 msgId，聊天页原地跳转定位
                                onTap: _scoped && (msgId?.isNotEmpty ?? false)
                                    ? () => Navigator.of(context).pop(msgId)
                                    : null,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 14, vertical: 12),
                                  decoration: BoxDecoration(
                                    color: context.cs.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                        color: context.cs.outlineVariant),
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // 2026-09-29：发送人头像 + 昵称（服务端批量补发）
                                      AppAvatar(
                                        url: m['senderAvatar']?.toString() ?? '',
                                        name: _senderName(m),
                                        size: 34,
                                        background: AppTheme.primary,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(_senderName(m),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                    color: context
                                                        .cs.onSurfaceVariant)),
                                            const SizedBox(height: 4),
                                            Text(_preview(m),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 14,
                                                    color:
                                                        context.cs.onSurface)),
                                            if (!_scoped) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                  t('searchConvLabel', {
                                                    'id':
                                                        '${m['conversationId']}'
                                                  }),
                                                  style: TextStyle(
                                                      fontSize: 12,
                                                      color: context.cs
                                                          .onSurfaceVariant)),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
          ),
        ],
      ),
    );
  }
}
