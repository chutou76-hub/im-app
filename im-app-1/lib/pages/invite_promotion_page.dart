import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/feature_flags.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_back_button.dart';
import '../widgets/app_dialogs.dart';

/// 邀请推广中心（2026-11-11 需求1，全民邀请码模式）。
///
/// 用户中心「我的邀请码」入口在全民模式下跳本页：
///   - 顶部：我的邀请码（点击复制）+ 推广总金额（好友付费 3 级分销佣金合计）+ 邀请好友数；
///   - 列表：邀请的好友（头像 / 昵称 / ID / 邀请时间），分页加载。
/// 数据源：GET /api/v1/invite/promotion。
class InvitePromotionPage extends StatefulWidget {
  const InvitePromotionPage({super.key});

  @override
  State<InvitePromotionPage> createState() => _InvitePromotionPageState();
}

class _InvitePromotionPageState extends State<InvitePromotionPage> {
  final _api = ApiClient.instance;
  final _scroll = ScrollController();

  bool _loading = true;
  bool _failed = false;
  String _inviteCode = '';
  double _totalAmount = 0;
  int _totalFriends = 0;
  List<Map<String, dynamic>> _list = [];
  int _page = 1;
  bool _loadingMore = false;
  bool _hasMore = true;

  // 奖励记录（2026-11-11 需求3）：分销佣金 + 邀新奖励两类流水，独立分页
  List<Map<String, dynamic>> _rewards = [];
  int _rewardPage = 1;
  int _rewardTotal = 0;
  bool _loadingRewards = false;
  bool _rewardHasMore = true;

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  // 滚到底自动加载下一页
  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 120) {
      _loadMore();
    }
  }

  Future<Map<String, dynamic>?> _fetch(int page,
      {int? rewardPage}) async {
    final rp = rewardPage ?? page;
    final r = await _api.get(
        '/api/v1/invite/promotion?page=$page&size=20&rewardPage=$rp&rewardSize=20');
    return (r.data['data'] as Map?)?.cast<String, dynamic>();
  }

  Future<void> _load() async {
    try {
      final d = await _fetch(1);
      if (!mounted) return;
      setState(() {
        _inviteCode = d?['myInviteCode']?.toString() ?? '';
        _totalAmount =
            (double.tryParse('${d?['totalAmount'] ?? 0}') ?? 0).toDouble();
        _totalFriends = (d?['totalFriends'] as num?)?.toInt() ?? 0;
        _list = ((d?['list'] as List?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _page = 1;
        _hasMore = _list.length < _totalFriends;
        // 奖励记录第 1 页（2026-11-11 需求3）
        _rewards = ((d?['rewards'] as List?) ?? [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _rewardTotal = (d?['rewardTotal'] as num?)?.toInt() ?? 0;
        _rewardPage = 1;
        _rewardHasMore = _rewards.length < _rewardTotal;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _failed = true; });
    }
  }

  // 奖励记录加载下一页（独立于好友列表分页；失败静默，不打断页面）
  Future<void> _loadMoreRewards() async {
    if (_loadingRewards || !_rewardHasMore) return;
    setState(() => _loadingRewards = true);
    try {
      final d = await _fetch(1, rewardPage: _rewardPage + 1);
      if (!mounted) return;
      final more = ((d?['rewards'] as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      setState(() {
        _rewards.addAll(more);
        _rewardPage += 1;
        _rewardHasMore = _rewards.length < _rewardTotal && more.isNotEmpty;
        _loadingRewards = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingRewards = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final d = await _fetch(_page + 1);
      if (!mounted) return;
      final more = ((d?['list'] as List?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      setState(() {
        _list.addAll(more);
        _page += 1;
        _hasMore = _list.length < _totalFriends && more.isNotEmpty;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _copyCode() {
    final t = AppLocalizations.instance.t;
    if (_inviteCode.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _inviteCode));
      AppDialogs.toast(context, t('meCopied'));
    }
  }

  /// 2026-11-11 需求：邀请好友按钮——复制后台配置的 App 下载地址，
  /// 提示「App下载地址已复制」；未配置时提示先到后台设置
  void _copyInviteUrl() {
    final t = AppLocalizations.instance.t;
    final url = FeatureFlags.instance.appDownloadUrl.value.trim();
    if (url.isEmpty) {
      AppDialogs.toast(context, t('inviteUrlNotSet'));
      return;
    }
    Clipboard.setData(ClipboardData(text: url));
    AppDialogs.toast(context, t('inviteUrlCopied'));
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.instance.t;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const AppBackButton(),
        title: Text(t('meInvitePromotion'),
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(t('promotionLoadFailed'),
                          style: TextStyle(color: AppTheme.textSecondary)),
                      const SizedBox(height: 12),
                      TextButton(onPressed: _load, child: Text(t('promotionRetry')))
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: () async => _load(),
                  child: ListView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _headerCard(),
                      const SizedBox(height: 16),
                      // 奖励记录（2026-11-11 需求3）：分销佣金 + 邀新奖励两类现金流水
                      Text(t('promotionRewards'),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      if (_rewards.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(
                              child: Text(t('promotionRewardsEmpty'),
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 13))),
                        )
                      else ...[
                        ..._rewards.map(_rewardTile),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: _loadingRewards
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : _rewardHasMore
                                    ? TextButton(
                                        onPressed: _loadMoreRewards,
                                        child: Text(t('promotionLoadMore'),
                                            style: const TextStyle(
                                                fontSize: 13)))
                                    : Text(t('promotionNoMore'),
                                        style: TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 12)),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Text(t('promotionFriends'),
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      if (_list.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: Center(
                              child: Text(t('promotionEmpty'),
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 13))),
                        )
                      else
                        ..._list.map(_friendTile),
                      if (_loadingMore)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ),
    );
  }

  // 顶部卡片：邀请码（可复制）+ 推广总金额 + 邀请好友数
  Widget _headerCard() {
    final t = AppLocalizations.instance.t;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 我的邀请码行（点击复制）
          InkWell(
            onTap: _copyCode,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Text(t('promotionMyCode'),
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textSecondary)),
                  const Spacer(),
                  Text(_inviteCode.isEmpty ? '-' : _inviteCode,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2)),
                  const SizedBox(width: 6),
                  Icon(Icons.copy_rounded,
                      size: 16, color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _statCell(t('promotionTotalAmount'),
                    '¥${_totalAmount.toStringAsFixed(2)}'),
              ),
              Container(width: 1, height: 36, color: AppTheme.divider),
              Expanded(
                child: _statCell(
                    t('promotionInviteCount'), '$_totalFriends'),
              ),
            ],
          ),
          // 2026-11-11 需求：邀请好友按钮——复制 App 下载地址分享
          // 2026-11-11 修复：固定高 44 + 主题默认 vertical:14 padding 导致 .icon
          // 变体内容区只剩 ~16px，中文文字上下被裁；显式收紧垂直 padding
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 44,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _copyInviteUrl,
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
              label: Text(t('promotionInviteBtn'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCell(String label, String value) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(
                fontSize: 12, color: AppTheme.textSecondary)),
      ],
    );
  }

  // 奖励记录条目：标题 / 金额（正数绿色加号）/ 时间（2026-11-11 需求3）
  Widget _rewardTile(Map<String, dynamic> r) {
    final title = r['title']?.toString() ?? '';
    final amount = (double.tryParse('${r['amount'] ?? 0}') ?? 0);
    final time = r['time']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(time,
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          Text('+¥${amount.toStringAsFixed(2)}',
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.green)),
        ],
      ),
    );
  }

  // 好友条目：头像 / 昵称 / ID / 时间
  Widget _friendTile(Map<String, dynamic> f) {
    final nickname = f['nickname']?.toString() ?? '';
    final id = f['id']?.toString() ?? '';
    final time = f['time']?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          AppAvatar(url: f['avatar']?.toString() ?? '', name: nickname, size: 42),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nickname.isEmpty ? id : nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text('ID: $id',
                    style: TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
            ),
          ),
          Text(time,
              style: TextStyle(
                  fontSize: 12, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}
