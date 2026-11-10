import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/user_cache.dart';
import '../theme/design2026.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_net_image.dart';

/// 朋友圈帖子卡（2026-11-07 三页新版式，对照 moments.html .post）：
/// 微信式布局——左头像、右列（昵称 14/700 primary、时间 11 text-3 + ·地区），
/// 正文/媒体/操作/社交盒整体左缩进（朋友圈页 52、资料页 feed 44）。
/// 点赞/评论改「⋯ 展开式」；社交盒 #F2F4F8（点赞行 + 评论行，带头像）。
///
/// 朋友圈页（moments_page）传交互回调全功能使用；资料页（user_profile_page）
/// 传 readOnly: true 作纯展示 feed（仅自己的帖子保留删除入口）。
/// 状态（liked/likeCount/comments）直接读写 [post] map，由父层 setState 驱动刷新。
class MomentPostCard extends StatefulWidget {
  final Map<String, dynamic> post;

  /// 头像尺寸（朋友圈页 40 / 资料页 34）
  final double avatarSize;

  /// 正文/媒体/操作/社交盒的左缩进（朋友圈页 52 / 资料页 44）
  final double indent;

  /// 纯展示模式（资料页 feed）：不显示 ⋯ 展开与评论回复入口
  final bool readOnly;

  /// 纯展示模式下仍允许删自己的帖子（资料页「点自己帖子删除」）
  final bool allowDelete;

  final VoidCallback? onAvatarTap;
  final void Function(Map<String, dynamic> post)? onLike;
  final void Function(Map<String, dynamic> post, Map<String, dynamic>? reply)?
      onComment;
  final void Function(Map<String, dynamic> post, String commentId)?
      onDeleteComment;
  final void Function(Map<String, dynamic> post, String postId)? onDelete;
  final void Function(List<String> urls, int index)? onOpenImages;
  final void Function(String url)? onSaveImage;
  final void Function(String url)? onOpenVideo;

  /// 整卡点击（资料页 → 进完整朋友圈页）
  final VoidCallback? onCardTap;

  const MomentPostCard({
    super.key,
    required this.post,
    this.avatarSize = 40,
    this.indent = 52,
    this.readOnly = false,
    this.allowDelete = false,
    this.onAvatarTap,
    this.onLike,
    this.onComment,
    this.onDeleteComment,
    this.onDelete,
    this.onOpenImages,
    this.onSaveImage,
    this.onOpenVideo,
    this.onCardTap,
  });

  @override
  State<MomentPostCard> createState() => _MomentPostCardState();
}

class _MomentPostCardState extends State<MomentPostCard> {
  /// ⋯ 展开/收起（赞 / 评论 文字按钮，带动画）
  bool _toolsOpen = false;

  /// 评论折叠（2026-11-07 夜13，对照设计稿 c-more）：默认只显示 5 条，
  /// 「还有 x 条评论」点击展开全部；帖子切换时重置折叠态
  bool _commentsExpanded = false;
  String _commentsKey = '';

  @override
  void didUpdateWidget(covariant MomentPostCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final key = (widget.post['id'] ?? widget.post['postId'] ?? '').toString();
    if (_commentsKey.isNotEmpty && key != _commentsKey) {
      _commentsExpanded = false;
    }
    _commentsKey = key;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final p = widget.post;
    final name = (p['senderName'] ?? '').toString();
    final avatar = (p['senderAvatar'] ?? '').toString();
    final userId = (p['userId'] ?? '').toString();
    final content = (p['content'] ?? '').toString();
    final images = ((p['images'] as List<dynamic>?) ?? [])
        .map((e) => e.toString())
        .toList();
    final videos = ((p['videos'] as List<dynamic>?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final likeCount = (p['likeCount'] as num?)?.toInt() ?? 0;
    final liked = p['liked'] == true;
    final hidden = p['hidden'] == true;
    final reviewStatus = (p['reviewStatus'] as num?)?.toInt() ?? 1;
    final mine = p['mine'] == true;
    final time = (p['createdAt'] ?? '').toString();
    // 地区：市优先（直辖市/「市辖区」「县」占位回退省），无地区不加
    final pv = (p['province'] ?? '').toString();
    final ct = (p['city'] ?? '').toString();
    String locPart = '';
    if (ct.isNotEmpty && ct != '市辖区' && ct != '县') {
      locPart = ct;
    } else if (pv.isNotEmpty) {
      locPart = pv;
    }
    final timeText = locPart.isEmpty ? time : '$time · $locPart';
    final comments = ((p['comments'] as List<dynamic>?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final hasSocial = likeCount > 0 || liked || comments.isNotEmpty;

    final card = Container(
      color: D2026.surface,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头部：头像 + 昵称/时间列
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: widget.onAvatarTap,
                child: AppAvatar(
                  url: avatar,
                  name: name,
                  size: widget.avatarSize,
                  radius: widget.avatarSize / 2,
                  background: D2026.avatarBg(userId),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: D2026.primary)),
                        ),
                        if (p['assistant'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: D2026.primary.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(t('momentsOfficial'),
                                style: const TextStyle(
                                    fontSize: 10, color: D2026.primary)),
                          ),
                        ],
                        const Spacer(),
                        if (hidden) ...[
                          const Icon(Icons.lock_outline,
                              size: 13, color: D2026.text3),
                          const SizedBox(width: 3),
                          Text(t('momentsOnlyMe'),
                              style: const TextStyle(
                                  fontSize: 11, color: D2026.text3)),
                        ],
                        // 审核中（橙）/ 未通过（红）：仅发布者本人可见的标识
                        if (reviewStatus == 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF8F1F)
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(t('momentsReviewing'),
                                style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFFFF8F1F))),
                          ),
                        ] else if (reviewStatus == 2) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: D2026.error.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(t('momentsReviewRejected'),
                                style: const TextStyle(
                                    fontSize: 10, color: D2026.error)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(timeText,
                        style:
                            const TextStyle(fontSize: 11, color: D2026.text3)),
                  ],
                ),
              ),
            ],
          ),
          // 缩进列：正文 / 媒体 / 操作 / 社交盒（微信式：从昵称列开始）
          Padding(
            padding: EdgeInsets.only(left: widget.indent),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (content.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(content,
                        style: const TextStyle(
                            fontSize: 14, color: D2026.text2, height: 1.6)),
                  ),
                if (images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _images(images),
                  ),
                if (videos.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _video(videos.first),
                  ),
                // ⋯ 展开式 赞/评论（纯展示模式只保留自己的删除入口）
                if (!widget.readOnly || (widget.allowDelete && mine))
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        // 展开/收起 赞·评论（max-width + opacity 动画，对照 tool-actions）
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.centerRight,
                          child: _toolsOpen && !widget.readOnly
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  _toolBtn(
                                    icon: liked
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    label: t(liked ? 'momentsLiked' : 'momentsLike'),
                                    color: liked ? D2026.accent : D2026.text2,
                                    onTap: widget.onLike == null
                                        ? null
                                        : () => widget.onLike!(p),
                                  ),
                                  const SizedBox(width: 8),
                                  _toolBtn(
                                    icon: Icons.chat_bubble_outline,
                                    label: t('momentsComment'),
                                    color: D2026.text2,
                                    onTap: widget.onComment == null
                                        ? null
                                        : () => widget.onComment!(p, null),
                                  ),
                                ])
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(width: 8),
                        // ⋯ 更多按钮（28px surface-2 圆角）
                        if (!widget.readOnly)
                          InkWell(
                            onTap: () => setState(() => _toolsOpen = !_toolsOpen),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: D2026.surface2,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.more_horiz,
                                  size: 16, color: D2026.text3),
                            ),
                          ),
                        // 自己的帖子：删除入口（朋友圈页/资料页通用）
                        if (mine && widget.onDelete != null) ...[
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => widget.onDelete!(p,
                                (p['id'] ?? '').toString()),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: D2026.surface2,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.delete_outline,
                                  size: 16, color: D2026.text3),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                // 点赞/评论社交盒（无赞无评论不显示）
                if (hasSocial) _socialBox(liked, likeCount, comments),
              ],
            ),
          ),
        ],
      ),
    );

    if (widget.onCardTap == null) return card;
    return InkWell(onTap: widget.onCardTap, child: card);
  }

  /// 赞 / 评论 文字按钮（13px，激活态 accent）
  Widget _toolBtn({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ]),
      ),
    );
  }

  /// 点赞/评论社交盒（#F2F4F8 圆角 8）：点赞行 + 评论行
  Widget _socialBox(bool liked, int likeCount, List<Map<String, dynamic>> comments) {
    final t = AppLocalizations.of(context).t;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: D2026.socialBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 点赞行：accent 心形 + 叠放小头像 + primary 昵称文案
          if (likeCount > 0 || liked)
            Padding(
              padding: const EdgeInsets.only(bottom: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.favorite, size: 13, color: D2026.accent),
                  const SizedBox(width: 5),
                  if (liked) ...[
                    // 我的小头像（白描边 20px 圆）
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: D2026.socialBg, width: 1.5),
                      ),
                      child: AppAvatar(
                        url: (UserCache.myAvatar ?? '').toString(),
                        name: (UserCache.myProfileData?['nickname'] ?? '')
                            .toString(),
                        size: 17,
                        radius: 8.5,
                        background: D2026.primary,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
                  Expanded(
                    child: Text(
                      // likeCount 已包含「我」；仅有 liked 无计数时按 1 展示
                      t('momentsLikedBy',
                          {'count': '${likeCount > 0 ? likeCount : 1}'}),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: D2026.primary),
                    ),
                  ),
                ],
              ),
            ),
          // 评论行：迷你头像 + 「昵称：内容」/「昵称 回复 昵称：内容」
          // 2026-11-07（夜13）评论折叠：默认只显示前 5 条，
          // 超出显示「还有 x 条评论」点击展开全部，展开后可「收起」（对照设计稿 c-more）
          if (comments.isNotEmpty) ...[
            const SizedBox(height: 2),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0;
                    i < (_commentsExpanded ? comments.length : comments.length > 5 ? 5 : comments.length);
                    i++) ...[
                  if (i > 0) const SizedBox(height: 6),
                  _commentRow(comments[i]),
                ],
                if (comments.length > 5)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _commentsExpanded = !_commentsExpanded),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6, bottom: 1),
                      child: Text(
                        _commentsExpanded
                            ? t('momentsCollapseComments')
                            : t('momentsMoreComments', {
                                'count': '${comments.length - 5}'
                              }),
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: D2026.primary),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 评论单行：点按 = 回复该评论；长按自己的评论 = 删除（朋友圈页交互）
  Widget _commentRow(Map<String, dynamic> c) {
    final t = AppLocalizations.of(context).t;
    final cname = (c['senderName'] ?? '').toString();
    final ctext = (c['content'] ?? '').toString();
    final cid = (c['id'] ?? '').toString();
    final mine = c['userId']?.toString() == UserCache.myId;
    final replyName = (c['replyToName'] ?? '').toString();
    final interactive =
        !widget.readOnly && (widget.onComment != null || widget.onDeleteComment != null);
    return GestureDetector(
      onTap: interactive && widget.onComment != null
          ? () => widget.onComment!(widget.post, c)
          : null,
      onLongPress:
          interactive && mine && widget.onDeleteComment != null
              ? () => widget.onDeleteComment!(widget.post, cid)
              : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppAvatar(
            url: (c['senderAvatar'] ?? '').toString(),
            name: cname,
            size: 22,
            radius: 11,
            background: D2026.avatarBg((c['userId'] ?? '').toString()),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(
                    text: '$cname ',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: D2026.primary)),
                if (replyName.isNotEmpty)
                  TextSpan(
                      text: '${t('momentsReplyTo')} $replyName：',
                      style: const TextStyle(
                          fontSize: 11, color: D2026.text2)),
                TextSpan(
                    text: ctext,
                    style:
                        const TextStyle(fontSize: 12, color: D2026.text2)),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// 媒体区（微信式）：1 张=大图限宽 62%；2 张=一行均分；
  /// 3+ 张=每行三个的九宫格（gap 4 圆角 6）。
  /// 意图+2026-11-07：图片不裁剪——只限制宽度，高度按原图比例自适应
  /// （2026-11-07 用户反馈：feed 图片被 4/3、1:1 固定比例裁剪，改为限宽不限高）。
  Widget _images(List<String> imgs) {
    final list = imgs.take(9).toList();
    const gap = 4.0;
    return LayoutBuilder(builder: (context, box) {
      final maxW = box.maxWidth.isFinite ? box.maxWidth : 300.0;
      if (list.length == 1) {
        final w = maxW * 0.62;
        return GestureDetector(
          onTap: widget.onOpenImages == null
              ? null
              : () => widget.onOpenImages!(list, 0),
          onLongPress: widget.onSaveImage == null
              ? null
              : () => widget.onSaveImage!(list.first),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: AppNetImage(
                url: list.first,
                width: w,
                cacheWidth: (w * 2).round()),
          ),
        );
      }
      final tile = (maxW - gap * 2) / 3;
      // 意图+2026-11-07：九宫格瓦片恢复统一方形格子（行行对齐），图片
      // BoxFit.contain 完整显示不裁剪，格子底垫黑色——横图上下、竖图左右
      // 自动出现黑边补齐（用户确认的方案：宁要黑边不要裁剪）。
      Widget tileW(String url) => GestureDetector(
            onTap: widget.onOpenImages == null
                ? null
                : () => widget.onOpenImages!(list, list.indexOf(url)),
            onLongPress: widget.onSaveImage == null
                ? null
                : () => widget.onSaveImage!(url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: tile,
                height: tile,
                color: Colors.black,
                alignment: Alignment.center,
                child: AppNetImage(
                    url: url,
                    width: tile,
                    height: tile,
                    fit: BoxFit.contain,
                    cacheWidth: (tile * 2).round()),
              ),
            ),
          );
      return Wrap(spacing: gap, runSpacing: gap, children: [
        for (final img in list) tileW(img),
      ]);
    });
  }

  /// 视频瓦片：16/10 限宽 62%（最大 230），封面 + 44px 半透明播放圆钮 + 时长角标
  Widget _video(Map<String, dynamic> v) {
    final thumb = (v['thumb'] ?? '').toString();
    final url = (v['url'] ?? '').toString();
    final durationSec = (v['duration'] as num?)?.toInt() ?? 0;
    return LayoutBuilder(builder: (context, box) {
      final maxW = box.maxWidth.isFinite ? box.maxWidth : 300.0;
      final w = (maxW * 0.62).clamp(120.0, 230.0);
      final h = w * 10 / 16;
      return GestureDetector(
        onTap: widget.onOpenVideo == null || url.isEmpty
            ? null
            : () => widget.onOpenVideo!(url),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: [
                thumb.isNotEmpty
                    ? AppNetImage(url: thumb, fit: BoxFit.cover)
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF39435F), Color(0xFF54688C)],
                          ),
                        ),
                      ),
                Center(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.42),
                    ),
                    child: const Icon(Icons.play_arrow,
                        size: 26, color: Colors.white),
                  ),
                ),
                if (durationSec > 0)
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(D2026.fmtDuration(durationSec),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    });
  }
}
