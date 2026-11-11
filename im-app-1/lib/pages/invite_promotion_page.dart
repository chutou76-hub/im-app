import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:qr_flutter/qr_flutter.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/feature_flags.dart';
import '../theme/app_theme.dart';
import '../utils/image_saver.dart';
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

  // 推广素材海报（2026-11-11 需求）：底图 + 本人二维码 + 邀请码，合成后存相册
  /// 海报截图锚点（RepaintBoundary → toImage → PNG 字节 → 相册）
  final GlobalKey _posterKey = GlobalKey();
  /// 服务端拼好的带参数推广链接（二维码内容 / 复制用）；空 = 后台未配置
  String _promoLink = '';
  /// 海报底图 URL（后台可配；空 → 纯色渐变底）
  String _posterUrl = '';
  /// 本人昵称（海报标题「XXX 邀请你加入」用；仅无底图的渐变模式使用）
  String _nickname = '';
  /// 保存中（防重复点击 + 按钮 loading）
  bool _savingPoster = false;

  // 二维码在素材底图上的落位（2026-11-11 需求，百分比 0~100）：
  //   _qrX/_qrY = 二维码**中心**占底图宽/高的百分比，_qrSize = 边长占底图**宽度**的百分比。
  // 默认值对齐官方 3:4 素材（1086×1448）白框实测：内白区 (403,965)-(682,1248)
  // → 中心 (49.95%, 76.44%)、边长占宽 25.78%。后台可改，换素材不必发版。
  double _qrX = FeatureFlags.instance.promoQrX.value;
  double _qrY = FeatureFlags.instance.promoQrY.value;
  double _qrSize = FeatureFlags.instance.promoQrSize.value;
  /// 素材底图真实宽高比（null = 还没解析出来 → 暂按 3:4）。
  /// 用真实比例而非固定 3:4：底图若不是 3:4，BoxFit.cover 会裁边，
  /// 百分比坐标就会整体偏移、二维码落到白框外面。
  double? _posterAspect;
  /// 已解析过比例的底图 URL（避免每次 setState 重复注册 image stream 监听）
  String _posterAspectUrl = '';

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
        // 推广素材海报数据（2026-11-11）：链接 / 底图 / 昵称
        _promoLink = (d?['promoLink']?.toString() ?? '').trim();
        _nickname = (d?['nickname']?.toString() ?? '').trim();
        _posterUrl = (d?['promoPosterUrl']?.toString() ?? '').trim();
        // 底图回退：服务端没下发 → 用 /auth/config 的后台配置；再空 → 纯色渐变
        if (_posterUrl.isEmpty) {
          _posterUrl = FeatureFlags.instance.promoPosterUrl.value.trim();
        }
        // 二维码落位（2026-11-11）：优先取本接口下发值，缺字段（老服务端）时
        // 回退 /auth/config 的值，再回退内置默认。0 是合法坐标，故不用 ?? 兜底。
        _qrX = _pctOr(d?['promoQrX'], FeatureFlags.instance.promoQrX.value, 0, 100);
        _qrY = _pctOr(d?['promoQrY'], FeatureFlags.instance.promoQrY.value, 0, 100);
        _qrSize = _pctOr(
            d?['promoQrSize'], FeatureFlags.instance.promoQrSize.value, 5, 100);
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
      // 解析素材底图的真实宽高比（2026-11-11）：海报容器必须与底图同比例，
      // 否则 BoxFit.cover 会裁边、二维码的百分比坐标随之偏移出白框。
      _resolvePosterAspect(_posterUrl);
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

  /// 复制推广链接（服务端拼好的带参数链接，好友打开即可绑定邀请关系）。
  /// 按钮仅在链接非空时渲染，这里再兜一层空判断（静默返回，不再提示
  /// `promoLinkNotSet`——2026-11-11 口径1：该文案已由海报内的邀请码卡片取代）。
  void _copyLink() {
    final t = AppLocalizations.instance.t;
    if (_promoLink.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _promoLink));
    AppDialogs.toast(context, t('promoLinkCopied'));
  }

  /// 解析素材底图的真实宽高比（2026-11-11 需求：二维码按百分比落位）。
  ///
  /// 只读尺寸、不接管图片生命周期：[ImageInfo].image 归 ImageCache 所有，
  /// 这里**不能** dispose——否则会把缓存里的同一张图销毁，列表里其它位置
  /// 引用同一 URL 的图片会变空白。
  void _resolvePosterAspect(String url) {
    if (url.isEmpty || _posterAspectUrl == url) return;
    _posterAspectUrl = url;
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final w = info.image.width;
        final h = info.image.height;
        if (mounted && w > 0 && h > 0) {
          final a = w / h;
          if (_posterAspect != a) setState(() => _posterAspect = a);
        }
        stream.removeListener(listener);
      },
      onError: (_, __) => stream.removeListener(listener),
    );
    stream.addListener(listener);
  }

  /// 2026-11-11 需求改版：把「底图 + 本人二维码」的推广素材海报
  /// 截图存相册（原「保存后台固定二维码」逻辑废弃——固定码无法绑定邀请关系）。
  ///
  /// 实现：RepaintBoundary → toImage → PNG 字节 → ImageSaver。
  /// **链接为空也允许保存**（2026-11-11 口径1）：海报里的二维码位此时换成
  /// 「大号邀请码 + 手填提示」卡片，仍是一张可转发的推广图——「二维码能不能
  /// 生成」不该是「海报能不能保存」的前置条件（开关未开/链接未配时用户
  /// 同样需要发图）。只有截图失败才提示保存失败。
  Future<void> _savePoster() async {
    final t = AppLocalizations.instance.t;
    if (_savingPoster) return;
    setState(() => _savingPoster = true);
    try {
      final boundary = _posterKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) {
          setState(() => _savingPoster = false);
          AppDialogs.toast(context, t('promoPosterSaveFailed'));
        }
        return;
      }
      // 按「目标宽 ~1200px」反推倍率（2026-11-11）：素材模式底图是运营实拍/设计图，
      // 固定 3 倍在窄屏手机上只有 ~960px，放大看会糊；夹在 2~4 之间既清晰
      // 又不至于让 toImage 的内存爆掉（4 倍 ≈ 2.4MP）。
      final pr = (1200 / boundary.size.width).clamp(2.0, 4.0);
      final image = await boundary.toImage(pixelRatio: pr);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      // 及时释放原生图像内存（高倍图较大）
      image.dispose();
      final Uint8List? bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          setState(() => _savingPoster = false);
          AppDialogs.toast(context, t('promoPosterSaveFailed'));
        }
        return;
      }
      final safeCode = _inviteCode.isEmpty ? 'code' : _inviteCode;
      final ok = await ImageSaver.saveBytes(bytes, name: 'promo_$safeCode.png');
      if (!mounted) return;
      setState(() => _savingPoster = false);
      AppDialogs.toast(
          context, t(ok ? 'promoPosterSaved' : 'promoPosterSaveFailed'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _savingPoster = false);
      AppDialogs.toast(context, t('promoPosterSaveFailed'));
    }
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
          // 2026-11-11 需求改版：推广素材海报——底图 + 本人二维码 + 邀请码，
          // 用户直接保存成图片发朋友圈 / 群，扫码下载即自动绑定邀请关系
          const SizedBox(height: 14),
          _posterCard(),
          const SizedBox(height: 14),
          // 2026-11-11 修复：固定高 44 + 主题默认 vertical:14 padding 导致 .icon
          // 变体内容区只剩 ~16px，中文文字上下被裁；显式收紧垂直 padding，
          // 高度提至 48 彻底消除裁切
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.green,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppTheme.green.withValues(alpha: 0.4),
                disabledForegroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              // 2026-11-11 口径1：链接为空也允许保存（海报会降级为邀请码卡片）
              onPressed: _savingPoster ? null : _savePoster,
              icon: _savingPoster
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download_rounded, size: 20),
              label: Text(t('promotionInviteBtn'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          // 复制推广链接（次要操作；后台没配链接时不显示）
          if (_promoLink.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.green,
                  side: BorderSide(color: AppTheme.green.withValues(alpha: 0.5)),
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _copyLink,
                icon: const Icon(Icons.link_rounded, size: 18),
                label: Text(t('promoCopyLink'),
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 海报底（无底图 / 底图加载失败时）：深绿纯色渐变，保证白色二维码
  /// 容器与白色文字都有足够对比度
  Widget _posterGradientBg() {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B6B36), AppTheme.green],
        ),
      ),
    );
  }

  /// 推广素材海报（2026-11-11 需求改版）。
  ///
  /// 分两种形态：
  /// - **素材模式**（后台配了底图 promo_poster_url）：底图原样铺满，只把二维码按
  ///   promo_qr_x / promo_qr_y / promo_qr_size 三个百分比落进素材上的白框，
  ///   **不叠加任何文字与压暗层**——素材图自带「邀请好友一起赚钱」这类文案，
  ///   再叠一层会和图里的排版打架（用户实测反馈）。
  /// - **渐变模式**（没配底图）：内置「昵称 + 二维码 + 邀请码 + 提示」排版兜底。
  ///
  /// 2026-11-11 口径1：`promoLink` 为空（开关关 / 未配推广链接 / 用户无码）时
  /// 二维码位降级为「大号邀请码」卡片，海报仍可保存转发。
  Widget _posterCard() {
    return _posterUrl.isNotEmpty ? _materialPoster() : _gradientPoster();
  }

  /// 素材模式海报：底图 + 二维码精准落进白框。
  ///
  /// 两个关键点：
  /// 1. 容器比例取底图**真实宽高比**（[_posterAspect]）。若固定 3:4，非 3:4 素材会被
  ///    BoxFit.cover 裁掉上下/左右，百分比坐标随之整体偏移、二维码落到白框外面。
  /// 2. 用 LayoutBuilder 拿实际渲染尺寸算 left/top/size，预览与截图完全一致
  ///    （RepaintBoundary 所见即所得）。
  Widget _materialPoster() {
    final aspect =
        (_posterAspect != null && _posterAspect! > 0) ? _posterAspect! : 3 / 4;
    return RepaintBoundary(
      key: _posterKey,
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              // 二维码白底块边长：默认 25.78%，正好等于官方素材白框宽度
              final side = (w * _qrSize / 100).clamp(1.0, w);
              // 以 (X%, Y%) 为中心摆放，并夹在画布内——后台填错也不会画到图外
              final left = (w * _qrX / 100 - side / 2).clamp(0.0, w - side);
              final top = (h * _qrY / 100 - side / 2).clamp(0.0, h - side);
              return Stack(
                fit: StackFit.expand,
                children: [
                  // 加载占位（2026-11-11）：底图首帧未到时先铺浅灰，
                  // 否则海报区域会透出卡片白底、看起来像"图挂了"
                  const ColoredBox(color: Color(0xFFF1F1F1)),
                  Image.network(
                    _posterUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _posterGradientBg(),
                  ),
                  Positioned(
                    left: left,
                    top: top,
                    width: side,
                    height: side,
                    child: _qrSlot(side),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// 二维码白底块（素材模式用）。
  ///
  /// 白底 + 8% 内边距是刻意的：QR 码四周必须有留白（静区）才扫得出来，
  /// 若二维码直接顶到素材的红色描边上，扫码成功率会明显下降。
  Widget _qrSlot(double side) {
    final t = AppLocalizations.instance.t;
    final pad = side * 0.08;
    final inner = side - pad * 2;
    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(side * 0.07),
      ),
      child: _promoLink.isNotEmpty
          ? QrImageView(
              data: _promoLink,
              size: inner,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square, color: Colors.black),
              dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Colors.black),
            )
          // 无推广链接（开关关 / 未配 / 无码）：白框里放大号邀请码，让对方手填。
          // 此时绝不出现「扫码」字样，否则误导用户。
          : Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      t('promotionMyCode'),
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ),
                  SizedBox(height: inner * 0.10),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _inviteCode.isEmpty ? '-' : _inviteCode,
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: inner * 0.22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: inner * 0.04,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// 渐变模式海报（后台没配素材底图时兜底）：深绿渐变 + 昵称 + 白底二维码 +
  /// 邀请码 + 扫码提示。竖版 3:4，整块包在 RepaintBoundary 里，保存即截图。
  Widget _gradientPoster() {
    final t = AppLocalizations.instance.t;
    final hasLink = _promoLink.isNotEmpty;
    final title = _nickname.isEmpty
        ? t('promoPosterTitle')
        : '$_nickname\n${t('promoPosterTitle')}';
    return RepaintBoundary(
      key: _posterKey,
      child: AspectRatio(
        aspectRatio: 3 / 4,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _posterGradientBg(),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        height: 1.3,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 二维码白底容器（白底 + 深色码，任何背景下都能扫）；
                    // 无推广链接时降级为「我的邀请码 + 大号邀请码」卡片。
                    Container(
                      width: 148,
                      height: 148,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: hasLink
                          ? QrImageView(
                              data: _promoLink,
                              size: 128,
                              version: QrVersions.auto,
                              backgroundColor: Colors.white,
                              eyeStyle: const QrEyeStyle(
                                  eyeShape: QrEyeShape.square,
                                  color: Colors.black),
                              dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square,
                                  color: Colors.black),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  t('promotionMyCode'),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textSecondary),
                                ),
                                const SizedBox(height: 6),
                                // 大号邀请码：等宽 + 加字距，方便对方照着手填
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _inviteCode.isEmpty ? '-' : _inviteCode,
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 3,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    // 二维码下方：我的邀请码 + 邀请码（有码场景）
                    // 无码场景邀请码已在大号卡片里展示，这里不再重复
                    if (hasLink) ...[
                      const SizedBox(height: 10),
                      Text(
                        t('promotionMyCode'),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _inviteCode.isEmpty ? '-' : _inviteCode,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2.4,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                    // 小字提示：有二维码才提「扫码」；没有码时改为提示手填
                    // （无码场景下绝不出现"扫码"字样，否则误导用户）
                    const SizedBox(height: 10),
                    Text(
                      t(hasLink ? 'promoQrHint' : 'promoCannotScanTip'),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
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

/// 解析服务端下发的百分比配置（2026-11-11 需求：推广海报二维码落位）。
///
/// 语义：字段缺失 / 非数字 → 返回 [def]；有值 → 夹到 [lo, hi]。
/// 注意 **0 是合法坐标**（贴左/贴顶），不能用 `?? def` 或 `> 0` 判断"未配置"，
/// 否则运营把二维码调到左边缘时会被静默改回默认位置。
double _pctOr(Object? raw, double def, double lo, double hi) {
  if (raw == null) return def;
  final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
  if (v == null || v.isNaN || v.isInfinite) return def;
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}
