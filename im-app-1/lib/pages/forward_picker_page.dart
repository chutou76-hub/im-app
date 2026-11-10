import '../widgets/app_back_button.dart';
import 'dart:convert'; // 2026-10-07：_previewOf 按 kind 区分 12 码（合并转发/转账回执）

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/friend_service.dart';
import '../services/local_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';

/// 转发 / 创建聊天 共用的选人页（2026-10-07 按微信标准行为重做）。
///
/// 版式（对齐微信「选择聊天」）：
///   - 标题栏：左「关闭」 / 中标题（转发=「选择聊天」，创建聊天=「创建聊天」）/ 右「多选」；
///   - 搜索框；
///   - 「最近转发」：横滑头像行（转发过的目标，去重置顶，不限条数）；
///   - 「最近聊天」：会话列表统一混排（私聊 + 群聊），**与消息列表同数据同排序**
///     （`ConversationService.list()`，最后消息时间倒序），带最后一条消息预览；
///   - 搜索态：隐藏两个分区，直接展示「好友 + 群聊」全量匹配结果。
///
/// 交互：
///   - 单选（默认）：点任意一行立即 pop 单个结果；
///   - 多选：点行 = 勾选，底部浮出「确定 (N)」，pop 列表（由调用方批量发送）。
///   - 多选不自动开启，但**勾选到 ≥1 项后自动进入多选态**（与微信一致）。
///
/// pop 返回：
///   单选 → `{'kind':'friend'|'group','id':String,'nickname':String,'avatar':String?}`
///   多选 → `List<Map<String,dynamic>>`（同单选结构，可批量）
class ForwardPickerPage extends StatefulWidget {
  final String myId;
  /// 页面标题（默认「选择聊天」）
  final String? title;
  /// 是否允许多选（转发消息 true；创建聊天 false）
  final bool allowMulti;
  const ForwardPickerPage({
    super.key,
    required this.myId,
    this.title,
    this.allowMulti = true,
  });

  @override
  State<ForwardPickerPage> createState() => _ForwardPickerPageState();
}

class _ForwardPickerPageState extends State<ForwardPickerPage> {
  final _friendSvc = FriendService();
  final _convSvc = ConversationService();
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _friends = [];
  List<ConvItem> _convs = [];
  List<Map<String, dynamic>> _recentForward = [];
  bool _loading = true;
  bool _loadFailed = false;
  bool _multi = false; // 多选态
  final Set<String> _picked = {}; // 选中键：'friend:<id>' / 'group:<id>'

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await _friendSvc.list();
      final convs = await _convSvc.list();
      final recent = await LocalStore.loadRecentForward();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _convs = convs;
        _recentForward = recent;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  /// 好友显示名：备注优先
  String _friendName(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ?? u['account'] ?? '').toString();
  }

  /// 通讯录好友（2026-10-07 需求3：转发也要能选通讯录里的全部好友，
/// 因为「最近聊天」不一定包含我全部的通讯录好友）。
  /// 排除已在「最近聊天」里出现过的会话，避免重复行。
  List<Map<String, dynamic>> get _contactRows {
    final seen = <String>{};
    for (final c in _recentChats()) {
      seen.add(_keyOf('${c['kind']}', '${c['id']}'));
    }
    final out = <Map<String, dynamic>>[];
    for (final u in _friends) {
      final id = (u['id'] ?? '').toString();
      if (id.isEmpty) continue;
      if (seen.contains(_keyOf('friend', id))) continue;
      out.add({
        'kind': 'friend',
        'id': id,
        'nickname': _friendName(u),
        'avatar': (u['avatar'] ?? '').toString(),
      });
    }
    return out;
  }

  /// 最近聊天项（微信式统一条目）：私聊取对方昵称、群聊取群名，附最后消息预览。
  /// 与消息列表同源（ConversationService.list()），故排序/内容天然一致。
  List<Map<String, dynamic>> _recentChats() {
    final out = <Map<String, dynamic>>[];
    for (final c in _convs) {
      final isGroup = (c.conversation['type'] as num?)?.toInt() == 2;
      out.add({
        'kind': isGroup ? 'group' : 'friend',
        'id': isGroup ? c.id : c.peerId,
        'nickname': c.conversationName,
        'avatar': c.avatarUrl,
        'preview': _previewOf(c),
        'time': _fmtTime(c.lastMessage?['createdAt']),
        'online': !isGroup && c.peerOnline,
      });
    }
    return out;
  }

  /// 时间显示（微信式）：今天只显示 HH:mm，昨天显示「昨天」，更早显示 MM-dd / YYYY-MM-DD。
  /// ⚠️ 2026-10-07 修：原先直接 `createdAt.toString()` 把服务端 ISO 串
  /// （如 2026-10-08T01:05:00Z）整段塞进 trailing 文本，导致行宽被撑爆 → 搜索时灰屏。
  String _fmtTime(Object? raw) {
    if (raw == null) return '';
    final s = raw.toString().trim();
    if (s.isEmpty) return '';
    final dt = DateTime.tryParse(s);
    if (dt == null) return '';
    final now = DateTime.now();
    final d = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    final hm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    if (diff == 0) return hm;
    if (diff == 1) return '昨天';
    if (dt.year == now.year) {
      return '${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// 最后一条消息预览文本。
  /// 2026-10-07 修：
  /// ① 补齐 6（系统消息）——原先落到兜底把 JSON 打进列表（用户反馈「显示数组」）；
  /// ② **12 是冲突码**：服务端 MsgMergeForward（合并转发）与 MsgTransferReceipt
  ///    （转账回执，我上一批把回执从 11 挪到 12 时没查 11 已被链接卡占用，也没
  ///    注意到 12 已被合并转发占用）→ 12 需按 content.kind 区分：
  ///    kind=transferReceipt → 转账回执；否则（带 v/count/items）→ 聊天记录。
  /// ③ 未知类型一律兜底「[消息]」，绝不把 JSON 内容透给用户。
  String _previewOf(ConvItem c) {
    final m = c.lastMessage;
    if (m == null) return '';
    final type = (m['type'] as num?)?.toInt() ?? 1;
    // 特殊类型一律显示方括号标签，不透出 JSON
    const labels = <int, String>{
      2: '[图片]',
      3: '[文件]',
      4: '[语音]',
      5: '[视频]',
      6: '[系统消息]',
      7: '[通话]',
      8: '[红包]',
      9: '[转账]',
      10: '[名片]',
      11: '[链接]',
      12: '[聊天记录]',
      // 15 = 转账回执：用户要求与转账同义，直接显示「转账」，不另起文案
      15: '[转账]',
      14: '[位置]',
    };
    final lb = labels[type];
    if (lb != null) return lb;
    // 文本消息（type=1）：直接显示内容；其余未知类型兜底，绝不打印 JSON
    if (type == 1) return (m['content'] ?? '').toString();
    return '[消息]';
  }

  String _keyOf(String kind, String id) => '$kind:$id';

  /// 选中/取消（多选态）
  void _toggle(String kind, String id) {
    final k = _keyOf(kind, id);
    setState(() {
      if (_picked.contains(k)) {
        _picked.remove(k);
      } else {
        _picked.add(k);
        _multi = true; // 勾选后自动进入多选（微信行为）
      }
    });
  }

  /// 单选立即返回；多选则切换
  /// 「创建聊天」：打开**通讯录选人页**（好友 / 群聊两 Tab 的旧版单选列表）。
  ///
  /// 2026-10-07：之前误做成「再次 push 本页面（换个标题）」，用户明确纠正——
  /// 创建聊天要的是「从通讯录里挑一个好友/群聊直接开聊」，与转发选人的
  /// 「最近转发/最近聊天」是两种不同场景，故单独保留 [_ContactPickerPage]。
  Future<void> _openContactPicker() async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
          builder: (_) => _ContactPickerPage(myId: widget.myId)),
    );
    if (picked == null || !mounted) return;
    if (_multi) {
      _toggle('${picked['kind']}', '${picked['id']}');
      return;
    }
    _popSingle(picked);
  }

  void _onTap(Map<String, dynamic> row) {
    final kind = '${row['kind']}';
    final id = '${row['id']}';
    if (kind == 'group' && id.isEmpty) return; // 无效会话
    if (_multi) {
      _toggle(kind, id);
      return;
    }
    _popSingle(row);
  }

  void _popSingle(Map<String, dynamic> row) {
    Navigator.pop(context, {
      'kind': row['kind'],
      'id': '${row['id']}',
      'nickname': row['nickname'],
      'avatar': row['avatar'],
    });
  }

  void _confirmMulti() {
    final list = <Map<String, dynamic>>[];
    for (final row in _recentChats()) {
      final k = _keyOf('${row['kind']}', '${row['id']}');
      if (_picked.contains(k)) {
        list.add({
          'kind': row['kind'],
          'id': '${row['id']}',
          'nickname': row['nickname'],
          'avatar': row['avatar'],
        });
      }
    }
    // \u540c\u65f6\u5305\u542b\u201c\u6700\u8fd1\u8f6c\u53d1\u300d\u91cc\u9009\u4e2d\u7684\u76ee\u6807\uff08\u53ef\u80fd\u4e0d\u5728\u6700\u8fd1\u804a\u5929\u5217\u8868\u91cc\uff09
    for (final r in _recentForward) {
      final k = _keyOf('${r['kind']}', '${r['id']}');
      if (_picked.contains(k)) {
        final dup = list.any((e) =>
            '${e['kind']}' == '${r['kind']}' && '${e['id']}' == '${r['id']}');
        if (!dup) {
          list.add({
            'kind': r['kind'],
            'id': '${r['id']}',
            'nickname': r['nickname'],
            'avatar': r['avatar'],
          });
        }
      }
    }
    if (list.isEmpty) return;
    Navigator.pop(context, list);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final q = _searchCtrl.text.trim().toLowerCase();
    final title = widget.title ?? t('forwardPickerTitle');

    // 搜索态：好友 + 群聊 全量匹配
    // ⚠️ 2026-10-07 修两处：① 搜索结果原先**没带 preview/time**，导致命中行显示
    // 原始 JSON 数组（与「最近聊天」行的 [转账] 等标签不一致）；
    // ② id 用 c.peerId 直接取值，若为 null 会抛异常 → 整页灰屏，改安全兜底。
    List<Map<String, dynamic>> searchRows = <Map<String, dynamic>>[];
    if (q.isNotEmpty) {
      for (final u in _friends) {
        final name = _friendName(u);
        if ('$name ${u['account'] ?? ''}'.toLowerCase().contains(q)) {
          searchRows.add({
            'kind': 'friend',
            'id': (u['id'] ?? '').toString(),
            'nickname': name,
            'avatar': (u['avatar'] ?? '').toString(),
            'preview': '',
            'time': '',
            'online': false,
          });
        }
      }
      for (final c in _convs) {
        final name = c.conversationName;
        if (name.toLowerCase().contains(q) ||
            c.peerShortId.toLowerCase().contains(q)) {
          final isGroup = (c.conversation['type'] as num?)?.toInt() == 2;
          searchRows.add({
            'kind': isGroup ? 'group' : 'friend',
            'id': isGroup ? c.id : (c.peerId.isEmpty ? '' : c.peerId),
            'nickname': name,
            'avatar': c.avatarUrl,
            // 2026-10-07：与「最近聊天」行同源，保证搜索结果也显示 [转账]/[图片] 等标签
            'preview': _previewOf(c),
            'time': _fmtTime(c.lastMessage?['createdAt']),
            'online': !isGroup && c.peerOnline,
          });
        }
      }
      // 无效会话（单聊但 peerId 为空）不展示——否则点进去也无会话可进
      searchRows = searchRows
          .where((r) => '${r['id']}'.isNotEmpty)
          .toList();
    }

    // 2026-10-07：列表构建包一层错误边界 —— 任何未预料异常（如某条会话字段缺失）
    // 最多让列表区域显示兜底文案，不再整页灰屏（此前搜索时命中异常即黑屏）。
    return ErrorBoundary(
      fallback: Center(
        child: Text(t('newConvNoContacts'),
            style: TextStyle(color: context.cs.onSurfaceVariant)),
      ),
      child: Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        title: Text(title, style: const TextStyle(fontSize: 17)),
        leading: TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('forwardPickerClose'),
              style: const TextStyle(fontSize: 15)),
        ),
        leadingWidth: 68,
        actions: [
          if (widget.allowMulti)
            TextButton(
              onPressed: () => setState(() {
                _multi = !_multi;
                if (!_multi) _picked.clear();
              }),
              child: Text(
                  _multi
                      ? t('forwardPickerCancelMulti')
                      : t('forwardPickerMulti'),
                  style: TextStyle(
                      fontSize: 15,
                      color: _multi ? AppTheme.primary : null)),
            ),
        ],
        actionsPadding: const EdgeInsets.only(right: 8),
      ),
      body: Column(
        children: [
          // ===== 搜索框（2026-10-07 改 V2 胶囊式，与通讯录/群资料页一致）=====
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                hintText: t('newConvSearchHint'),
                hintStyle: TextStyle(
                    fontSize: 14, color: context.cs.onSurfaceVariant),
                prefixIcon: Icon(Icons.search,
                    size: 18, color: context.cs.onSurfaceVariant),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 36, minHeight: 32),
                filled: true,
                fillColor: context.cs.onSurfaceVariant
                    .withValues(alpha: 0.10),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide(
                      color: context.cs.outlineVariant, width: 0.5),
                ),
              ),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else if (_loadFailed)
            Expanded(
              child: Center(
                child: Text(t('newConvNoContacts'),
                    style: TextStyle(color: context.cs.onSurfaceVariant)),
              ),
            )
          else
            Expanded(
              child: q.isNotEmpty
                  // 搜索态：全量匹配结果
                  ? (searchRows.isEmpty
                      ? Center(
                          child: Text(t('newConvNoContacts'),
                              style:
                                  TextStyle(color: context.cs.onSurfaceVariant)))
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 12),
                          itemCount: searchRows.length,
                          separatorBuilder: (_, __) => Divider(
                              height: 1,
                              indent: 68,
                              endIndent: 16,
                              color: context.cs.outlineVariant),
                          itemBuilder: (_, i) => _targetRow(searchRows[i]),
                        ))
                  // 浏览态：最近转发 + 最近聊天
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        if (_recentForward.isNotEmpty) ...[
                          _sectionTitle(t('forwardRecentForward')),
                          _recentForwardStrip(),
                        ],
                        _sectionTitle(
                          t('forwardRecentChat'),
                          // 2026-10-07：「创建聊天」入口 → 跳**通讯录选人页**
                          // （旧的「好友 / 群聊」两 Tab 那种单选列表，不是本页面自身）
                          action: TextButton(
                            onPressed: () => _openContactPicker(),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(t('forwardCreateChatTitle'),
                                style: const TextStyle(
                                    fontSize: 13, color: AppTheme.primary)),
                          ),
                        ),
                        ..._recentChats().map(_targetRow),
                        // 2026-10-07：转发也要能选**通讯录里的全部好友**
                        // （最近聊天未必包含所有好友），故在列表下方追加通讯录分区。
                        if (q.isEmpty && _contactRows.isNotEmpty) ...[
                          _sectionTitle(t('forwardContactsAll')),
                          ..._contactRows.map(_targetRow),
                        ],
                      ],
                    ),
            ),
          // ===== 多选底部操作条 =====
          if (_multi && _picked.isNotEmpty)
            SafeArea(
              top: false,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                color: context.cs.surface,
                child: FilledButton(
                  onPressed: _confirmMulti,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    minimumSize: const Size.fromHeight(46),
                  ),
                  child: Text(
                    t('newConvConfirm', {'count': '${_picked.length}'}),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  /// 分区标题（「最近转发」/「最近聊天」）；[action] 为右侧可选操作
  /// 2026-10-07：样式对齐 V2（16px 左边距、13.5 半粗、sub 色），与设置页分区标题一致。
  Widget _sectionTitle(String text, {Widget? action}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(text,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
            ),
            if (action != null) action,
          ],
        ),
      );

  /// 「最近转发」横滑头像行（微信式，可横滚；末尾带一个「+」占位）
  Widget _recentForwardStrip() {
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _recentForward.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (_, i) {
          final r = _recentForward[i];
          final k = _keyOf('${r['kind']}', '${r['id']}');
          final on = _multi && _picked.contains(k);
          return GestureDetector(
            onTap: () => _onTap({
              'kind': r['kind'],
              'id': r['id'],
              'nickname': r['nickname'],
              'avatar': r['avatar'],
            }),
            child: SizedBox(
              width: 56,
              child: Column(
                children: [
                  Stack(
                    children: [
                      AppAvatar(
                        url: (r['avatar'] ?? '').toString(),
                        name: (r['nickname'] ?? '').toString(),
                        size: 56,
                        background: AppTheme.primary,
                      ),
                      if (on)
                        Container(
                          width: 20,
                          height: 20,
                          alignment: Alignment.center,
                          decoration: const BoxDecoration(
                            color: AppTheme.primary,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.check,
                              size: 13, color: Colors.white),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('${r['nickname'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 目标行（最近聊天 / 搜索结果共用）：头像 + 名称 + 预览 + 时间 + 勾选
  Widget _targetRow(Map<String, dynamic> row) {
    final kind = '${row['kind']}';
    final id = '${row['id']}';
    final name = '${row['nickname'] ?? ''}';
    final preview = '${row['preview'] ?? ''}';
    final time = '${row['time'] ?? ''}';
    final online = row['online'] == true;
    final k = _keyOf(kind, id);
    final on = _multi && _picked.contains(k);

    return ListTile(
      onTap: () => _onTap(row),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: Stack(
        children: [
          AppAvatar(
            url: '${row['avatar'] ?? ''}',
            name: name,
            size: 42,
            background: AppTheme.primary,
          ),
          if (on)
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: AppTheme.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check, size: 13, color: Colors.white),
            ),
        ],
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w500)),
          ),
          if (online) ...[
            const SizedBox(width: 5),
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                  color: Color(0xFF4FA4EE), shape: BoxShape.circle),
            ),
          ],
        ],
      ),
      subtitle: preview.isEmpty
          ? null
          : Text(preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  TextStyle(fontSize: 12, color: context.cs.onSurfaceVariant)),
      trailing: _multi
          ? Icon(
              on ? Icons.check_circle : Icons.circle_outlined,
              size: 22,
              color: on ? AppTheme.primary : context.cs.onSurfaceVariant)
          : (time.isEmpty
              ? null
              : Text(time,
                  style: TextStyle(
                      fontSize: 11, color: context.cs.onSurfaceVariant))),
    );
  }
}

/// 极简错误边界（2026-10-07）：子树 build 抛异常时用 [fallback] 兜底。
/// 用途：选人页若某条会话字段异常，最多重进一次，不整页黑屏。
/// 注意：StatelessWidget 的 try/catch **只能拦住自己 build 内**的异常，
/// 这里包一层 `_SafelyBuild` 正是为了让 Scaffold 的整棵子树构建都在 try 内。
class ErrorBoundary extends StatelessWidget {
  final Widget child;
  final Widget fallback;
  const ErrorBoundary(
      {super.key, required this.child, required this.fallback});

  @override
  Widget build(BuildContext context) {
    try {
      return child;
    } catch (_) {
      return fallback;
    }
  }
}

/// 通讯录选人页（2026-10-07）——「创建聊天」专用。
///
/// 与 [ForwardPickerPage]（转发选人：最近转发 + 最近聊天）**是两种不同场景**：
/// 创建聊天 = 从通讯录里挑一个好友或群聊直接开聊，故这里保留最朴素的
/// 「好友 / 群聊」两 Tab 单选列表，点一行立即返回结果。
class _ContactPickerPage extends StatefulWidget {
  final String myId;
  const _ContactPickerPage({required this.myId});

  @override
  State<_ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends State<_ContactPickerPage>
    with SingleTickerProviderStateMixin {
  final _friendSvc = FriendService();
  final _convSvc = ConversationService();
  final _searchCtrl = TextEditingController();
  late final TabController _tab = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _friends = [];
  List<ConvItem> _groups = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final friends = await _friendSvc.list();
      final convs = await _convSvc.list();
      if (!mounted) return;
      setState(() {
        _friends = friends;
        _groups = convs.where((c) => c.conversation['type'] == 2).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _friendName(Map<String, dynamic> u) {
    final r = u['remark']?.toString() ?? '';
    if (r.isNotEmpty) return r;
    return (u['nickname'] ?? u['account'] ?? '').toString();
  }

  /// 「N 位成员」文案（群列表副标题）
  String _memberLabel(int count) =>
      AppLocalizations.of(context).t('groupMembersTitle', {'count': '$count'});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final q = _searchCtrl.text.trim().toLowerCase();
    final friends = q.isEmpty
        ? _friends
        : _friends
            .where((u) =>
                ('${_friendName(u)} ${u['account'] ?? ''}'.toLowerCase())
                    .contains(q))
            .toList();
    final groups = q.isEmpty
        ? _groups
        : _groups
            .where((c) => c.conversationName.toLowerCase().contains(q))
            .toList();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(t('forwardCreateChatTitle')),
        bottom: TabBar(
          controller: _tab,
          labelColor: AppTheme.primary,
          unselectedLabelColor: context.cs.onSurfaceVariant,
          indicatorColor: AppTheme.primary,
          tabs: [
            Tab(text: t('forwardTabFriends')),
            Tab(text: t('forwardTabGroups')),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: AppTheme.authInput(
                  hint: t('newConvSearchHint'), icon: Icons.search),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2)
          else
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: [
                  // 注意：子方法收的是**已取好的文案字符串**，不是取词条函数 t
                  _friendsTab(t('newConvNoContacts'), friends),
                  _groupsTab(t('newConvNoContacts'), groups),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// [emptyText] = 「暂无联系人」文案（由调用方取好后传入）
  Widget _friendsTab(String emptyText, List<Map<String, dynamic>> friends) {
    if (friends.isEmpty) {
      return Center(
          child: Text(emptyText,
              style: TextStyle(color: context.cs.onSurfaceVariant)));
    }
    return ListView.separated(
      itemCount: friends.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 68,
          endIndent: 16,
          color: context.cs.outlineVariant),
      itemBuilder: (_, i) {
        final u = friends[i];
        final name = _friendName(u);
        final id = (u['id'] ?? '').toString();
        return ListTile(
          onTap: () => Navigator.pop(context, {
            'kind': 'friend',
            'id': id,
            'nickname': name,
            'avatar': (u['avatar'] ?? '').toString(),
          }),
          leading: AppAvatar(
              url: (u['avatar'] ?? '').toString(),
              name: name,
              size: 42,
              background: AppTheme.primary),
          title: Text(name,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: (u['account'] ?? '').toString().isEmpty
              ? null
              : Text((u['account'] ?? '').toString(),
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
        );
      },
    );
  }

  /// [emptyText] = 「暂无联系人」文案（成员数文案在 _memberLabel 内自取）
  Widget _groupsTab(String emptyText, List<ConvItem> groups) {
    if (groups.isEmpty) {
      return Center(
          child: Text(emptyText,
              style: TextStyle(color: context.cs.onSurfaceVariant)));
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 68,
          endIndent: 16,
          color: context.cs.outlineVariant),
      itemBuilder: (_, i) {
        final c = groups[i];
        return ListTile(
          onTap: () => Navigator.pop(context, {
            'kind': 'group',
            'id': c.id,
            'nickname': c.conversationName,
            'avatar': c.avatarUrl,
          }),
          leading: AppAvatar(
              url: c.avatarUrl,
              name: c.conversationName,
              size: 42,
              background: AppTheme.primary),
          title: Text(c.conversationName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
          subtitle: c.memberCount > 0
              ? Text(_memberLabel(c.memberCount),
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant))
              : null,
        );
      },
    );
  }
}