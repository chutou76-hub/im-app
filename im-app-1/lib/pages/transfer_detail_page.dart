import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart'; // context.cs 扩展

/// 转账领取详情页（2026-10-07 需求4）
///
/// 由聊天页转账卡片点击进入（**转账人 / 被转账人都可点**）。数据来自
/// `GET /api/v1/wallet/transfer/:msgId`（服务端返回金额/发起人/发起时间/
/// 收款人/收款时间/是否已收款）。
///
/// 版式对齐设计稿（2026-10-07）：
///   - 顶部返回（**收款人视角无右上「…」**，转账人视角有）；
///   - 已收款 = 绿勾圆；待收款 = 蓝色时钟圆（收款人描边圈 / 转账人实心）；
///   - 金额下方提示语按视角分文案；收款人待收款时可点「收款」；
///   - 分隔线 + 转账时间 /（已收款的）收款时间；
///   - 底部：收款人待收款时可点「收款」；其余视角无底部操作。
class TransferDetailPage extends StatefulWidget {
  final String msgId;
  /// 2026-10-07：当前用户 id，用于区分「我是收款人」视角（决定时钟圆样式与文案）
  final String myId;
  const TransferDetailPage(
      {super.key, required this.msgId, required this.myId});

  @override
  State<TransferDetailPage> createState() => _TransferDetailPageState();
}

class _TransferDetailPageState extends State<TransferDetailPage> {
  Map<String, dynamic> _d = {};
  bool _loading = true;
  String _error = '';
  bool _accepting = false; // 收款中（防重复点击）

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final r = await WalletStore.instance.transferStatus(widget.msgId);
      if (!mounted) return;
      if (r == null) {
        setState(() {
          _loading = false;
          _error = 'load_failed';
        });
        return;
      }
      setState(() {
        _d = r;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'load_failed';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = context.cs;
    final claimed = _d['claimed'] == true;
    final amount = (_d['amount'] as num?)?.toDouble() ?? 0;
    final claimName = (_d['claimUserName'] ?? '').toString();
    final createdAt = (_d['createdAt'] ?? '').toString();
    final claimedAt = (_d['claimedAt'] ?? '').toString();
    final senderName = (_d['senderName'] ?? '').toString();
    final toName = (_d['toName'] ?? '').toString();
    // 2026-11-13 修复：实际收款人 id——优先服务端兜底解析的 payeeUserId，
    // 旧服务端未下发该字段时回落消息自带的 toUserId。
    final payeeId =
        ((_d['payeeUserId'] ?? _d['toUserId'] ?? '')).toString();
    // 2026-10-07 需求4 二收：视角分三类——
    //   我是收款人 / 我是转账人（双方）=> 完整「领取详情」（金额+操作）；
    //   其他成员（第三方）=> 仅「{sender}向{to}发起转账」+ 转账状态，无操作入口。
    // 优先用服务端 isParty（权威判定），未下发时回退本地两端比较。
    var isParty = _d['isParty'] == true;
    if (!_d.containsKey('isParty')) {
      final me = widget.myId;
      isParty = me.isNotEmpty &&
          ((_d['senderId'] ?? '').toString() == me ||
              payeeId == me);
    }
    final isThirdParty = !isParty;
    // 2026-11-13 修复「转账没办法收款」：收款人判定改用服务端兜底解析后的
    // payeeUserId（旧客户端发起的单聊转账 content.toUserId 是空串，此前
    // 按它判定会把收款人误判成第三方视角 → 详情页没有「收款」按钮）。
    final iAmPayee = !isThirdParty &&
        payeeId == widget.myId &&
        widget.myId.isNotEmpty;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        // 2026-10-07：返回键与聊天窗口统一（arrow_back_ios_new size 26），
        // 不用 AppBar 默认的左箭头
        automaticallyImplyLeading: false,
        leadingWidth: 48,
        leading: Padding(
          padding: const EdgeInsets.only(left: 8, right: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: Icon(Icons.arrow_back_ios_new,
                  size: 26, color: context.cs.onSurface),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            ),
          ),
        ),
        title: Text(t('transferDetailTitle')),
        titleTextStyle: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w600, color: cs.onSurface),
        // 2026-10-07：右上「…」三个视角**全部隐藏**（用户要求；
        // 详情页无任何操作菜单，只读）
        actions: null,
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: AppTheme.primary))
          : _error.isNotEmpty
              ? Center(
                  child: Text(t('transferDetailLoadFail'),
                      style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                )
              : Column(
                  children: [
                    const SizedBox(height: 40),
                    // ===== 状态圆：已收款=绿勾；待收款=蓝时钟（收款人描边圆 / 转账人实心）=====
                    Container(
                      width: 64,
                      height: 64,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        // 第三方：待收款时用中性灰（表示「不是我的事」）
                        color: claimed
                            ? const Color(0xFF07C160)
                            : (iAmPayee
                                ? Colors.white
                                : (isThirdParty
                                    ? const Color(0xFFB2B2B2)
                                    : const Color(0xFF1AADFF))),
                        shape: BoxShape.circle,
                        border: (!claimed && iAmPayee)
                            ? Border.all(color: const Color(0xFF1AADFF), width: 2)
                            : null,
                      ),
                      child: Icon(
                        claimed ? Icons.check_rounded : Icons.schedule_rounded,
                        size: 36,
                        color: (!claimed && iAmPayee)
                            ? const Color(0xFF1AADFF)
                            : Colors.white,
                      ),
                    ),
                    const SizedBox(height: 18),
                    // 状态文案
                    Text(
                      isThirdParty
                          // 第三方：只说人物关系，不暴露金额与操作入口
                          ? t('transferDetailBetween', {
                              'from': senderName.isEmpty ? 'A' : senderName,
                              'to': toName.isEmpty ? 'B' : toName,
                            })
                          : claimed
                              ? (claimName.isEmpty
                                  ? t('transferDetailReceived')
                                  : t('transferDetailReceivedBy',
                                      {'name': claimName}))
                              : (iAmPayee
                                  ? t('transferDetailWaitingMe')
                                  : t('transferDetailWaitingPeer')),
                      // 第三方：「{sender}向{to}发起转账」（不展示金额与操作）
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface),
                    ),
                    const SizedBox(height: 18),
                    // ===== 大号金额（三视角均展示）=====
                    Text(
                      '\u00a5${WalletStore.instance.fmt(amount)}',
                      style: const TextStyle(
                          fontSize: 48,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                          color: Color(0xFF111111)),
                    ),
                    // 待收款时的退还提示语（收款人：将退还给对方 / 转账人：将退还给你）
                    // 2026-10-07：第三方不显示（与自己无关）
                    if (!claimed && !isThirdParty) ...[
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Text(
                          iAmPayee
                              ? t('transferDetailRefundToPeer')
                              : t('transferDetailRefundToMe'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13, color: cs.onSurfaceVariant),
                        ),
                      ),
                    ],
                    const Spacer(),
                    // ===== 分隔线 + 时间行（已收款才显收款时间）=====
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          Divider(
                              height: 1,
                              color:
                                  cs.onSurfaceVariant.withValues(alpha: 0.12)),
                          const SizedBox(height: 16),
                          // 2026-10-07 需求4 二收：「转账状态」行（在「转账时间」上方）
                          _row(t('transferDetailStatusLabel'),
                              claimed
                                  ? t('transferDetailStatusClaimed')
                                  : t('transferDetailStatusPending')),
                          const SizedBox(height: 14),
                          _row(t('transferDetailTimeLabel'),
                              createdAt.isEmpty ? '-' : createdAt),
                          if (claimed) ...[
                            const SizedBox(height: 14),
                            _row(t('transferDetailClaimedLabel'),
                                claimedAt.isEmpty ? '-' : claimedAt),
                          ],
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                    const Spacer(),
                    // ===== 底部：收款人待收款可点「收款」 =====
                    if (!claimed && iAmPayee) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF07C160),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: _onAccept,
                            child: Text(
                              t('transferDetailAcceptBtn'),
                              style: const TextStyle(
                                  fontSize: 17, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        t('transferDetailRefundHint'),
                        style:
                            TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 40),
                    ],
                    // 2026-10-07：「账单详情」入口已按用户要求移除（因此除收款按钮外无其他底部操作）
                  ],
                ),
    );
  }

  /// 收款人点「收款」：调转账领取接口，成功后本页刷新。
  Future<void> _onAccept() async {
    // 独立方法里拿不到 build 的局部 t，用实例级 AppLocalizations
    final t = AppLocalizations.of(context).t;
    if (_accepting) return;
    setState(() => _accepting = true);
    try {
      final res = await WalletStore.instance.acceptTransfer(widget.msgId);
      if (!mounted) return;
      setState(() => _accepting = false);
      if (res == null) {
        // 失败：WalletStore 已写入 lastError，直接展示服务端原因
        AppDialogs.toast(
            context,
            WalletStore.instance.lastError.isNotEmpty
                ? WalletStore.instance.lastError
                : t('svcAcceptFailed'));
        return;
      }
      await WalletStore.instance.refresh();
      _load(); // 刷新详情页（状态圆 → 绿勾）
    } catch (e) {
      if (!mounted) return;
      setState(() => _accepting = false);
      AppDialogs.toast(context, '$e');
    }
  }

  /// 「标签 : 值」一行（标签左灰、值右深色）
  Widget _row(String label, String value) {
    final cs = context.cs;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style:
                TextStyle(fontSize: 15, color: cs.onSurfaceVariant)),
        Text(value,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: cs.onSurface)),
      ],
    );
  }
}