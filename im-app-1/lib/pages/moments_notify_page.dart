import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/moment_service.dart';
import '../services/moments_notify_store.dart';
import '../services/user_cache.dart';
import '../theme/design2026.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_net_image.dart';
import '../widgets/brand_loading.dart';
import 'moments_page.dart';

/// 朋友圈互动通知列表（2026-11-07 需求3；2026-11-07 版式对照 notifications.html）。
/// 数据：GET /api/v1/moment-notify/list；进入即调 POST /moment-notify/read 全部置已读
/// （朋友圈页与发现 tab 的红点随之清零）。点击条目 → 跳到该动态作者的朋友圈。
/// 新增：顶部筛选胶囊「全部 / 赞 / 评论」（客户端按 type 1=赞、2/3=评论过滤）。
class MomentsNotifyPage extends StatefulWidget {
  const MomentsNotifyPage({super.key});

  @override
  State<MomentsNotifyPage> createState() => _MomentsNotifyPageState();
}

class _MomentsNotifyPageState extends State<MomentsNotifyPage> {
  final _svc = MomentService.instance;
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;

  /// 筛选：0=全部 / 1=赞 / 2=评论（type 2/3 均算评论）
  int _filter = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _svc.notifyList();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // 进入页面即全部置已读（服务端 + 本地红点）
    await MomentsNotifyStore.instance.markRead();
  }

  String _actionText(int type) {
    final t = AppLocalizations.of(context).t;
    switch (type) {
      case 1:
        return t('momentsNotifyLike');
      case 3:
        return t('momentsNotifyReply');
      default:
        return t('momentsNotifyComment');
    }
  }

  /// 按筛选胶囊过滤：1=赞；2/3=评论
  List<Map<String, dynamic>> get _filtered {
    if (_filter == 0) return _list;
    return _list.where((n) {
      final type = (n['type'] as num?)?.toInt() ?? 0;
      return _filter == 1 ? type == 1 : (type == 2 || type == 3);
    }).toList();
  }

  /// 意图+2026-11-07：三页新版式（对照 notifications.html）——白底吸顶
  /// 32px 圆形返回按钮 + 「通知」标题，surface-2 胶囊筛选（全部/赞/评论），
  /// 列表项 42px 圆头像 + 两行文案 + 46px 帖子缩略图，项间 1px outline-2 分隔。
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final items = _filtered;
    return Scaffold(
      backgroundColor: D2026.surface,
      body: Column(
        children: [
          // 吸顶头部：返回 + 标题（白底 + outline-2 底边）
          Container(
            decoration: const BoxDecoration(
              color: D2026.surface,
              border: Border(
                  bottom: BorderSide(color: D2026.outline2)),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    // 32px surface-2 圆形返回按钮
                    InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: D2026.surface2),
                        child: const Icon(Icons.arrow_back_ios_new,
                            size: 16, color: D2026.text2),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(t('momentsNotifyNavTitle'),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: D2026.text1)),
                  ],
                ),
              ),
            ),
          ),
          // 筛选胶囊「全部 / 赞 / 评论」
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: D2026.surface2,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(children: [
              Expanded(child: _filterItem(0, t('notifyFilterAll'))),
              Expanded(child: _filterItem(1, t('notifyFilterLike'))),
              Expanded(child: _filterItem(2, t('momentsComment'))),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: BrandRingLoader())
                : items.isEmpty
                    ? Center(
                        child: Text(t('momentsNotifyEmpty'),
                            style: const TextStyle(
                                fontSize: 14, color: D2026.text3)))
                    : ListView.separated(
                        padding: const EdgeInsets.only(top: 4, bottom: 40),
                        itemCount: items.length,
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, thickness: 1, color: D2026.outline2),
                        itemBuilder: (ctx, i) => _item(items[i]),
                      ),
          ),
        ],
      ),
    );
  }

  /// 筛选 pill（与朋友圈页同款：激活 primary 底白字 + 阴影）
  Widget _filterItem(int i, String label) {
    final active = _filter == i;
    return GestureDetector(
      onTap: () {
        if (_filter != i) setState(() => _filter = i);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? D2026.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: D2026.primary.withValues(alpha: 0.30),
                      offset: const Offset(0, 4),
                      blurRadius: 12),
                ]
              : null,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : D2026.text2)),
      ),
    );
  }

  /// 通知条目：左 42px 圆头像 + 中间两行（昵称+动作+引用 / 时间）+ 右 46px 缩略图
  Widget _item(Map<String, dynamic> n) {
    final name = (n['actorName'] ?? '').toString();
    final avatar = (n['actorAvatar'] ?? '').toString();
    final excerpt = (n['postExcerpt'] ?? '').toString();
    final unread = n['unread'] == true;
    final postUserId = (n['postUserId'] ?? '').toString();
    final isMe = postUserId == (UserCache.myId ?? '');
    final type = (n['type'] as num?)?.toInt() ?? 0;
    return InkWell(
      onTap: () {
        // 跳到关联的朋友圈（动态作者的时间线；自己的动态回自己时间线）
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    MomentsPage(userId: isMe ? null : postUserId)));
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppAvatar(
                url: avatar,
                name: name,
                size: 42,
                radius: 21,
                background: D2026.avatarBg(postUserId)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 第一行：昵称（primary 600）+ 动作文案 + 引用内容（text-3）
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: name,
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: D2026.primary)),
                      TextSpan(
                          text: ' ${_actionText(type)}',
                          style: const TextStyle(
                              fontSize: 14, color: D2026.text2)),
                      if (excerpt.isNotEmpty)
                        TextSpan(
                            text: '：$excerpt',
                            style: const TextStyle(
                                fontSize: 14, color: D2026.text3)),
                      if (unread)
                        const WidgetSpan(
                            child: Padding(
                                padding: EdgeInsets.only(left: 6),
                                child: _UnreadDot()),
                            alignment: PlaceholderAlignment.middle),
                    ]),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 5),
                  // 第二行：时间
                  Text((n['createdAt'] ?? '').toString(),
                      style:
                          const TextStyle(fontSize: 11, color: D2026.text3)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _thumb(n),
          ],
        ),
      ),
    );
  }

  /// 右侧 46px 帖子缩略图：帖子首图；视频用封面 + 白色小三角播放标；
  /// 数据缺图时降级为浅蓝渐变占位（视频为深蓝灰渐变）
  Widget _thumb(Map<String, dynamic> n) {
    var img = (n['postImage'] ?? n['postThumb'] ?? n['postCover'] ?? '')
        .toString();
    if (img.isEmpty) {
      final imgs = (n['postImages'] as List<dynamic>?);
      if (imgs != null && imgs.isNotEmpty) img = imgs.first.toString();
    }
    final isVideo = n['postVideo'] == true ||
        (n['postType'] ?? '').toString() == 'video';
    if (isVideo) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 46,
          height: 46,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF39435F), Color(0xFF54688C)],
            ),
          ),
          child: const Icon(Icons.play_arrow, size: 18, color: Colors.white),
        ),
      );
    }
    if (img.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AppNetImage(url: img, width: 46, height: 46, cacheWidth: 92),
      );
    }
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFDCE8FB), Color(0xFFEAF1FE)],
        ),
      ),
    );
  }
}

/// 未读红点（8px）
class _UnreadDot extends StatelessWidget {
  const _UnreadDot();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: const BoxDecoration(
          color: D2026.error, shape: BoxShape.circle),
    );
  }
}
