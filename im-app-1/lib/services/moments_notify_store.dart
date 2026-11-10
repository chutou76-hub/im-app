import 'package:flutter/foundation.dart';

import 'moment_service.dart';

/// 全局朋友圈互动未读数（评论/点赞红点数据源，2026-10-10 需求3）。
///
/// 与 FriendReqStore / UnreadStore 同款单例 ValueNotifier 模式：
/// HomeShell 启动与回前台时 [refresh]，监听方：
///   - 底部导航「发现」tab 红点（home_shell.dart）
///   - 发现页「朋友圈」入口红点（discover_page.dart）
/// 进入朋友圈页（MomentsPage）时调 [markRead] 清零（服务端全部置已读）。
///
/// 说明：服务端目前没有朋友圈互动的 WS 事件推送，红点靠「启动 / 回前台 /
/// 打开朋友圈」三个时点拉取，与 FriendReqStore 的刷新节奏一致。
class MomentsNotifyStore {
  MomentsNotifyStore._();
  static final MomentsNotifyStore instance = MomentsNotifyStore._();

  final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// 重新拉取未读互动通知数。失败静默保留旧值。
  /// 2026-11-13：notifyUnread 返回 {unread, total}，红点仍取 unread。
  Future<void> refresh() async {
    try {
      final n = await MomentService.instance.notifyUnread();
      final v = n['unread'] ?? 0;
      if (count.value != v) count.value = v;
    } catch (_) {}
  }

  /// 进入朋友圈页：服务端全部置已读 + 本地红点清零。
  Future<void> markRead() async {
    count.value = 0;
    try {
      await MomentService.instance.notifyRead();
    } catch (_) {}
  }
}
