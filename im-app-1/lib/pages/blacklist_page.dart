import '../widgets/app_back_button.dart';
import 'package:flutter/material.dart';

import '../services/friend_service.dart';
import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';

/// 黑名单（2026-11-13/14 需求）：通讯录「新朋友」下方入口进入。
/// 显示被拉黑的用户列表（头像/昵称/账号），支持移出黑名单——
/// 移出后对方可重新搜索/申请添加好友（修复「拉黑后没法再拉出来」）。
class BlacklistPage extends StatefulWidget {
  const BlacklistPage({super.key});

  @override
  State<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends State<BlacklistPage> {
  final _svc = FriendService();
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;
  final Set<String> _removing = {}; // 正在移出中的用户 ID（防重复点击）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await _svc.blacklistList();
      if (mounted) {
        setState(() {
          _users = users;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> u) async {
    final t = AppLocalizations.of(context).t;
    final id = u['id']?.toString() ?? '';
    if (id.isEmpty) return;
    final name = (u['nickname']?.toString().isNotEmpty ?? false)
        ? u['nickname'].toString()
        : (u['account']?.toString() ?? id);
    final ok = await AppDialogs.confirm(
      context,
      title: t('blacklistRemove'),
      message: t('blacklistRemoveConfirm').replaceAll('{name}', name),
      danger: true,
    );
    if (ok != true) return;
    setState(() => _removing.add(id));
    try {
      final success = await _svc.blacklistRemove(id);
      if (!mounted) return;
      if (success) {
        AppDialogs.toast(context, t('blacklistRemovedToast'));
        _load();
      } else {
        AppDialogs.toast(context, t('blacklistRemoveFailed'));
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('blacklistRemoveFailed'));
    } finally {
      if (mounted) setState(() => _removing.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(t('blacklistTitle')),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _users.isEmpty
              ? Center(
                  child: Text(t('blacklistEmpty'),
                      style: TextStyle(color: context.cs.onSurfaceVariant)),
                )
              : RefreshIndicator(
                  onRefresh: () async => _load(),
                  child: ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics()),
                    padding: const EdgeInsets.all(16),
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => _tile(_users[i]),
                  ),
                ),
    );
  }

  Widget _tile(Map<String, dynamic> u) {
    final t = AppLocalizations.of(context).t;
    final id = u['id']?.toString() ?? '';
    final name = (u['nickname']?.toString().isNotEmpty ?? false)
        ? u['nickname'].toString()
        : (u['account']?.toString() ?? id);
    final account = u['account']?.toString() ?? '';
    final removing = _removing.contains(id);
    final color = AppTheme
        .avatarColors[name.hashCode.abs() % AppTheme.avatarColors.length];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          AppAvatar(
            url: u['avatar']?.toString() ?? '',
            name: name,
            size: 44,
            background: color,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: context.cs.onSurface)),
                if (account.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(account,
                      style: TextStyle(
                          fontSize: 12, color: context.cs.onSurfaceVariant)),
                ],
              ],
            ),
          ),
          InkWell(
            onTap: removing ? null : () => _remove(u),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: removing
                    ? context.cs.onSurfaceVariant.withValues(alpha: 0.3)
                    : AppTheme.danger,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(t('blacklistRemove'),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
