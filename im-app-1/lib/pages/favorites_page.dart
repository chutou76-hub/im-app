import 'dart:convert';

import '../widgets/app_back_button.dart';
import 'package:flutter/material.dart';

import '../constants/message_type.dart';
import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import 'forward_picker_page.dart';
import '../widgets/app_dialogs.dart';

/// 我的收藏：收藏的消息列表
/// 2026-11-08 收藏增强：
///   1. 列表项升级为 FavoriteItem（服务端超集结构）：含收藏 ID、发送者
///      昵称/短 ID、明文快照标记（E2E 文本收藏的是解密后明文）；
///   2. 长按弹窗「转发 / 删除」——转发复用聊天页黑名单口径（6/7/8/9 除外，
///      E2E 只有存了明文快照才可转、按普通文本发），删除调新 DELETE 接口；
///   3. 头部「会话 #xxx」改为「来自 昵称 id:xxx」。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  final _svc = ConversationService();
  List<Map<String, dynamic>> _favs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.favorites();
      if (mounted) {
        setState(() {
          _favs = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _preview(Map<String, dynamic> m) {
    final t = AppLocalizations.instance.t;
    final type = (m['type'] as num?)?.toInt() ?? 0;
    final content = m['content']?.toString() ?? '';
    switch (type) {
      case MessageType.image:
        return t('favoritesPreviewImage') + content;
      case MessageType.file:
        return t('favoritesPreviewFile') + content;
      case MessageType.voice:
        return t('favoritesPreviewVoice') + content;
      case MessageType.video:
        return t('favoritesPreviewVideo') + content;
      case MessageType.linkCard:
        // 链接卡片 content 是 JSON：优先展示卡片标题
        try {
          final j = jsonDecode(content);
          if (j is Map) {
            final title = (j['title'] ?? '').toString();
            if (title.isNotEmpty) return '${t('favoritesPreviewLink')} $title';
          }
        } catch (_) {}
        return t('favoritesPreviewLink') + content;
      case MessageType.mergeForward:
        return t('favoritesPreviewMerge') + content;
      case MessageType.location:
        return t('favoritesPreviewLocation') + content;
      default:
        // 文本（1）/E2E 明文快照（13）等：直接展示内容
        return content;
    }
  }

  /// 头部「来自 昵称 id:xxx」：短 ID 优先（与举报管理展示口径一致），无短 ID 回退雪花 ID
  String _fromText(Map<String, dynamic> m, String Function(String, [Map<String, String>?]) t) {
    final name = (m['senderName'] ?? '').toString();
    final shortId = (m['senderShortId'] ?? '').toString();
    final id = shortId.isNotEmpty ? shortId : (m['senderId'] ?? '').toString();
    return t('favoritesFrom', {'name': name, 'id': id});
  }

  String _time(String? iso) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return '';
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  // ===== 2026-11-08 长按动作：转发 / 删除 =====

  /// 转发：与聊天页同黑名单口径（6 系统/7 信令/8 红包/9 转账不可转）；
  /// E2E 文本仅当存了明文快照（plaintext=true）才可转，且按普通文本(type=1)发。
  Future<void> _forward(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context).t;
    final type = (m['type'] as num?)?.toInt() ?? 0;
    const notForwardable = {6, 7, 8, 9};
    if (notForwardable.contains(type) ||
        (type == MessageType.e2Text && m['plaintext'] != true)) {
      AppDialogs.toast(context, t('forwardNotAllowed'));
      return;
    }
    final picked = await Navigator.push<Map>(
      context,
      MaterialPageRoute(
          builder: (_) =>
              ForwardPickerPage(myId: UserCache.myId ?? '')),
    );
    if (picked == null || !mounted) return;
    final targetId = picked['id']?.toString() ?? '';
    if (targetId.isEmpty) return;
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await _svc.createDirect(targetId);
        convId = conv['id']?.toString() ?? '';
      }
      if (convId.isEmpty) throw Exception('no conversation');
      final content = m['content']?.toString() ?? '';
      if (type == MessageType.e2Text) {
        // 明文快照 → 按普通文本转发
        await _svc.sendRaw(convId, MessageType.text, content);
      } else {
        await _svc.sendRaw(convId, type, content,
            file: m['file'] as Map<String, dynamic>?);
      }
      if (!mounted) return;
      AppDialogs.toast(context, t('forwardSent'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('forwardNotAllowed'));
    }
  }

  /// 删除：确认后调 DELETE /message/favorite/:favId 并本地移除
  Future<void> _delete(int index) async {
    final t = AppLocalizations.of(context).t;
    final m = _favs[index];
    final ok = await AppDialogs.confirm(context,
        title: t('chatActionDelete'),
        message: t('favoritesDeleteConfirm'),
        danger: true);
    if (ok != true) return;
    try {
      final done =
          await _svc.favoriteDelete(m['favoriteId']?.toString() ?? '');
      if (!mounted) return;
      if (done) {
        setState(() => _favs.removeAt(index));
        AppDialogs.toast(context, t('chatDeleted'));
      } else {
        AppDialogs.toast(context, t('chatDeleteFailed'));
      }
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('chatDeleteFailed'));
    }
  }

  /// 长按弹层（微信式底部动作条：转发 / 删除 / 取消）
  Future<void> _showActions(int index) async {
    final t = AppLocalizations.of(context).t;
    final m = _favs[index];
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _actionTile(sheetCtx, Icons.reply_outlined, t('favoritesForward'),
                () async {
              Navigator.pop(sheetCtx);
              await _forward(m);
            }),
            _actionTile(sheetCtx, Icons.delete_outline,
                t('chatActionDelete'), () {
              Navigator.pop(sheetCtx);
              _delete(index);
            }, danger: true),
            const SizedBox(height: 8),
            _cancelTile(sheetCtx, t('cancel')),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _actionTile(BuildContext ctx, IconData icon, String label,
      VoidCallback onTap,
      {bool danger = false}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 22,
              color: danger ? const Color(0xFFE5484D) : ctx.cs.onSurface),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(
                  fontSize: 15,
                  color: danger
                      ? const Color(0xFFE5484D)
                      : ctx.cs.onSurface)),
        ]),
      ),
    );
  }

  Widget _cancelTile(BuildContext ctx, String label) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        width: double.infinity,
        height: 46,
        decoration: BoxDecoration(
          color: context.cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(leading: const AppBackButton(), title: Text(t('favoritesTitle'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _favs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.star_border,
                          size: 48, color: context.cs.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text(t('favoritesEmpty'),
                          style: TextStyle(color: context.cs.onSurfaceVariant)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _favs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final m = _favs[i];
                    return InkWell(
                      // 2026-11-08：长按弹「转发 / 删除」
                      onLongPress: () => _showActions(i),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: context.cs.surface,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.star,
                                    size: 14, color: Color(0xFFFFB800)),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                      _fromText(m, t),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: context.cs.onSurfaceVariant)),
                                ),
                                Text(_time(m['createdAt']?.toString()),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: context.cs.onSurfaceVariant)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(_preview(m),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14, color: context.cs.onSurface)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
