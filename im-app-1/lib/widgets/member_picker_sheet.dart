import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';

/// 群成员选择面板（2026-10-08，搜索「按成员筛选」用）。
///
/// 需求：**从成员列表里选一个人**，而不是手输昵称。选中后 `Navigator.pop`
/// 回传 `{'id': 雪花字符串, 'nickname': 显示名}`，由调用方拿去调搜索接口。
///
/// - 顶部搜索框：仅**前端**过滤列表（不发请求）；
/// - [isChannel] = true 时称谓用「订阅者」，头像行右侧显示「频道主」徽章；
/// - 选中项高亮；点已选中项 = 取消选择（pop null，由调用方清空筛选）。
class MemberPickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> members;
  final String selectedId;
  final bool isChannel;

  const MemberPickerSheet({
    super.key,
    required this.members,
    this.selectedId = '',
    this.isChannel = false,
  });

  @override
  State<MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends State<MemberPickerSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 显示名：群昵称 > 备注 > 昵称 > 账号（与 MemberSection / 群管理页同一口径）
  String _nameOf(Map<String, dynamic> m) {
    final t = AppLocalizations.of(context).t;
    final groupNick = m['groupNickname']?.toString().trim() ?? '';
    final remark = m['remark']?.toString() ?? '';
    final real = (m['nickname']?.toString().trim().isNotEmpty ?? false)
        ? m['nickname'].toString()
        : (m['account']?.toString() ?? t('contactsUser'));
    return groupNick.isNotEmpty
        ? groupNick
        : (remark.isNotEmpty ? remark : real);
  }

  String _idOf(Map<String, dynamic> m) =>
      m['id']?.toString() ?? m['userId']?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final kw = _ctrl.text.trim().toLowerCase();
    final list = kw.isEmpty
        ? widget.members
        : widget.members
            .where((m) =>
                '${_nameOf(m)} ${m['account'] ?? ''}'.toLowerCase().contains(kw))
            .toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.isChannel
                        ? t('searchFilterPickSubscriber')
                        : t('searchFilterPickMember'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close,
                      size: 20, color: context.cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 列表内搜索（仅前端过滤）
            TextField(
              controller: _ctrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                isDense: true,
                hintText: t('searchFilterMemberSearchHint'),
                hintStyle:
                    TextStyle(fontSize: 14, color: context.cs.onSurfaceVariant),
                prefixIcon: Icon(Icons.search,
                    size: 18, color: context.cs.onSurfaceVariant),
                filled: true,
                fillColor: context.cs.onSurfaceVariant.withValues(alpha: 0.08),
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
                  borderSide:
                      BorderSide(color: context.cs.outlineVariant, width: 0.5),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 成员列表（限高 60% 屏，成员多时可滚动）
            ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.5),
              child: list.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          t('searchFilterMemberEmpty'),
                          style: TextStyle(color: context.cs.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1,
                          indent: 56,
                          endIndent: 12,
                          color: context.cs.outlineVariant),
                      itemBuilder: (_, i) {
                        final m = list[i];
                        final id = _idOf(m);
                        final name = _nameOf(m);
                        final role = (m['role'] as num?)?.toInt() ?? 3;
                        final on = id.isNotEmpty && id == widget.selectedId;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: AppAvatar(
                              url: (m['avatar'] ?? '').toString(),
                              name: name,
                              size: 40,
                              background: AppTheme.primary),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: on
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: on
                                            ? AppTheme.primary
                                            : context.cs.onSurface)),
                              ),
                              // 频道主/群主徽章
                              if (role == 1) ...[
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: context.cs.onSurfaceVariant
                                        .withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.isChannel
                                        ? t('channelSubscribersOwner')
                                        : t('gmpRoleCreator'),
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: context.cs.onSurfaceVariant),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          trailing: on
                              ? Icon(Icons.check_circle,
                                  size: 20, color: AppTheme.primary)
                              : null,
                          onTap: () {
                            if (id.isEmpty) return;
                            // 点已选中项 = 取消选择（pop null → 调用方清空筛选）
                            if (on) {
                              Navigator.pop(context);
                              return;
                            }
                            Navigator.pop(context,
                                {'id': id, 'nickname': name});
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
