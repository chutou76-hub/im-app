import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart'; // 2026-10-07 hero 区拉 /user/profile
import '../services/shop_service.dart';
import '../services/vip_store.dart';
import '../services/wallet_store.dart';
import '../theme/app_theme.dart';
import '../widgets/app_avatar.dart'; // 2026-10-07 hero 头像（统一 URL 修正+默认头像兜底）
import '../widgets/app_dialogs.dart';
import '../widgets/v2_kit.dart';
import '../widgets/v2_settings.dart';

// ===== 设计稿复刻配色（vip.html / vanity.html，2026-10-06 UI 改版）=====
// 主色沿用 AppTheme.primary（V2 覆盖体系），SVIP 金/价格红按设计稿。
const Color _kGold = Color(0xFFC9A227);
const LinearGradient _kGoldGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFFF5C518), _kGold],
);

String _priceText(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// 靓号商城（2026-10-05，2026-10-06 按设计稿 vanity.html 复刻 UI）：
/// 胶囊搜索 + 分类 chips（服务端 type 过滤）+ 公告条 + 号码卡「选中→底部栏购买」。
/// 展示后台「靓号管理」上架（price>0 且未分配）的靓号，零钱余额购买后立即绑定。
/// 开关 shop_enabled 关闭时后端 4016 拒绝。
class ShopPage extends StatefulWidget {
  final VoidCallback? onBack;
  const ShopPage({super.key, this.onBack});
  @override
  State<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends State<ShopPage> {
  final _svc = ShopService.instance;
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  bool _buying = false;
  int _page = 1;
  int _total = 0;
  // 2026-10-06 UI 改版：分类 chips（0=全部，1 普通/2 豹子/3 顺子/4 VIP）+ 选中卡
  int _type = 0;
  int? _selected;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
    _scroll.addListener(() {
      if (_scroll.position.pixels >=
              _scroll.position.maxScrollExtent - 200 &&
          !_loadingMore &&
          _hasMore) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data =
          await _svc.listShortIds(keyword: _searchCtrl.text, type: _type);
      if (!mounted) return;
      setState(() {
        _total = (data['total'] as num?)?.toInt() ?? 0;
        _items = _mapList(data['list']);
        _page = 1;
        _hasMore = _items.length < _total;
        _selected = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppDialogs.toast(context, _errText(e));
    }
  }

  Future<void> _loadMore() async {
    setState(() => _loadingMore = true);
    try {
      final data = await _svc.listShortIds(
          page: _page + 1, keyword: _searchCtrl.text, type: _type);
      if (!mounted) return;
      final more = _mapList(data['list']);
      setState(() {
        _items.addAll(more);
        _page += 1;
        _hasMore = _items.length < _total;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  List<Map<String, dynamic>> _mapList(dynamic list) =>
      ((list as List<dynamic>?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  String _errText(Object e) => e.toString().replaceFirst('Exception: ', '');

  String _typeName(String Function(String, [Map<String, String>?]) t, int type) =>
      switch (type) {
        2 => t('shopTypeLeopard'),
        3 => t('shopTypeSequential'),
        4 => t('shopTypeVip'),
        _ => t('shopTypeNormal'),
      };

  /// 底部栏「立即购买」：确认弹窗 → 余额扣款绑定。
  /// 2026-10-05 修复：后端 ID 带 ,string tag 下发字符串，int.tryParse 兼容；
  /// 余额不足由后端 4101「余额不足」toast。
  Future<void> _buy(Map<String, dynamic> item) async {
    if (_buying) return;
    final t = AppLocalizations.of(context).t;
    final id = int.tryParse('${item['id']}') ?? 0;
    // 折后价优先（2026-10-06 需求13：shopDiscount 权益，后端按 finalPrice 结算）
    final price = (item['finalPrice'] as num?)?.toDouble() ??
        (item['price'] as num?)?.toDouble() ??
        0;
    final shortId = (item['shortId'] ?? '').toString();
    if (id <= 0) {
      AppDialogs.toast(context, t('shopEmpty'));
      return;
    }
    final ok = await AppDialogs.confirm(
      context,
      title: t('shopBuyConfirmTitle'),
      message: t('shopBuyConfirmMsg', {
        'price': price.toStringAsFixed(2),
        'id': shortId,
      }),
      confirmText: t('shopBuyNow'),
    );
    if (ok != true || !mounted) return;
    setState(() => _buying = true);
    try {
      await _svc.buyShortId(id);
      await WalletStore.instance.refresh(); // 余额变动即时上屏
      if (!mounted) return;
      AppDialogs.toast(context, t('shopBuySuccess'));
      _load(); // 刷新货架（该号已下架）
    } catch (e) {
      if (mounted) AppDialogs.toast(context, _errText(e));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          V2SetHeader(
            title: t('shopTitle'),
            onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
            backSpec: V2SetBackSpec.chevron, // 2026-10-06 需求3：对齐设计稿细雪佛龙，与聊天页全 App 标准一致
          ),
          _searchBar(t),
          _catTabs(t),
          _noticeBar(t),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Text(t('shopEmpty'),
                            style: TextStyle(
                                fontSize: 14,
                                color: context.cs.onSurfaceVariant)))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          controller: _scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
                          itemCount: _items.length + (_hasMore ? 1 : 0),
                          itemBuilder: (_, i) {
                            if (i >= _items.length) {
                              return Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: _loadingMore
                                        ? const CircularProgressIndicator(
                                            strokeWidth: 2)
                                        : null,
                                  ),
                                ),
                              );
                            }
                            return _shopCard(_items[i], i, t);
                          },
                        ),
                      ),
          ),
          _bottomBar(t),
        ],
      ),
    );
  }

  /// 胶囊搜索栏（设计稿 .search：白卡圆角 22、无边框）
  Widget _searchBar(String Function(String, [Map<String, String>?]) t) {
    final cs = context.cs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 3,
                offset: const Offset(0, 1)),
          ],
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _load(),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  // 2026-10-06 需求1：全局 inputDecorationTheme 是 filled 灰底，
                  // 搜索胶囊本体是白色，输入区必须透明白，否则一灰一白割裂
                  filled: false,
                  border: InputBorder.none,
                  hintText: t('shopSearchHint'),
                  hintStyle:
                      TextStyle(fontSize: 14, color: cs.onSurfaceVariant),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (_searchCtrl.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                onPressed: () {
                  _searchCtrl.clear();
                  _load();
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 分类 chips（设计稿 .cat-tabs：横向滚动、选中 primary 填充白字）
  Widget _catTabs(String Function(String, [Map<String, String>?]) t) {
    final cats = [
      (0, t('shopCatAll')),
      (1, t('shopTypeNormal')),
      (2, t('shopTypeLeopard')),
      (3, t('shopTypeSequential')),
      (4, t('shopTypeVip')),
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final (v, label) in cats)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () {
                  if (_type == v) return;
                  _type = v;
                  _load();
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: _type == v ? AppTheme.primary : context.cs.surface,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color:
                          _type == v ? AppTheme.primary : Colors.transparent,
                    ),
                  ),
                  child: Text(label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _type == v
                            ? Colors.white
                            : context.cs.onSurfaceVariant,
                      )),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 公告条（设计稿 .notice：浅蓝底圆角、info 图标 + 一次性收费文案）
  Widget _noticeBar(String Function(String, [Map<String, String>?]) t) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info, size: 14, color: AppTheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t('shopNotice'),
                style: TextStyle(fontSize: 12, color: AppTheme.primary)),
          ),
        ],
      ),
    );
  }

  /// 号码卡（设计稿 .num-card：徽标 + 大号码 + 价格块「一次性买断 ¥xx 永久」+「选这个」；
  /// 2026-10-06 交互改版：点卡片/按钮=选中（描边高亮），由底部栏统一下单）。
  /// 2026-10-06 需求13：已售靓号也展示（置灰 + 「已售」标识、不可选）；
  /// 会员折扣价 finalPrice 有值时显示折后红价 + 原价删除线。
  Widget _shopCard(Map<String, dynamic> item, int idx,
      String Function(String, [Map<String, String>?]) t) {
    final shortId = (item['shortId'] ?? '').toString();
    final rawPrice = (item['price'] as num?)?.toDouble() ?? 0;
    final fp = (item['finalPrice'] as num?)?.toDouble() ?? 0;
    final hasDiscount = fp > 0 && fp < rawPrice;
    final price = hasDiscount ? fp : rawPrice;
    final sold = (item['status'] as num?)?.toInt() == 3;
    final type = (item['type'] as num?)?.toInt() ?? 1;
    final cs = context.cs;
    final selected = !sold && _selected == idx;
    return GestureDetector(
      onTap: sold ? null : () => setState(() => _selected = idx),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: sold
              ? cs.onSurfaceVariant.withValues(alpha: 0.06)
              : selected
                  ? AppTheme.primary.withValues(alpha: 0.06)
                  : cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppTheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(_typeName(t, type),
                      style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.primary)),
                ),
                // 2026-10-07 设计稿对齐（vanity.html .badge.svip）：
                // 有会员折扣时按真实折扣率显示「SVIP x折」金渐变徽标
                if (hasDiscount) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      gradient: _kGoldGradient,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      // finalPrice/price 即实付比例，换算成折数（如 45/50 → 9 折）
                      t('shopSvipOff',
                          {'n': _priceText(rawPrice > 0 ? fp / rawPrice * 10 : 10)}),
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white),
                    ),
                  ),
                ],
                if (sold) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.onSurfaceVariant.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(t('shopSold'),
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurfaceVariant)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            Text(shortId,
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                    fontFamily: 'monospace',
                    color: sold ? cs.onSurfaceVariant : null)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('shopBuyout'),
                          style: TextStyle(
                              fontSize: 11, color: cs.onSurfaceVariant)),
                      const SizedBox(height: 2),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text('¥${_priceText(price)}',
                              style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: sold
                                      ? cs.onSurfaceVariant
                                      : const Color(0xFFF4511E))),
                          const SizedBox(width: 3),
                          Text(t('shopForever'),
                              style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant)),
                          // 会员折扣：原价删除线（2026-10-06 需求13）
                          if (hasDiscount) ...[
                            const SizedBox(width: 6),
                            Text('¥${_priceText(rawPrice)}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                    decoration: TextDecoration.lineThrough)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                if (!sold)
                  GestureDetector(
                    onTap: () => setState(() => _selected = idx),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(t('shopPick'),
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 底部固定栏（设计稿 .bottom-bar：已选靓号 + 合计 + 立即购买）
  Widget _bottomBar(String Function(String, [Map<String, String>?]) t) {
    final cs = context.cs;
    final sel = (_selected != null && _selected! < _items.length)
        ? _items[_selected!]
        : null;
    final price = sel == null
        ? 0.0
        : (sel['finalPrice'] as num?)?.toDouble() ??
            (sel['price'] as num?)?.toDouble() ??
            0;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            top: BorderSide(
                color: cs.onSurfaceVariant.withValues(alpha: 0.12))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('shopSelected'),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      sel == null
                          ? t('shopNone')
                          : (sel['shortId'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sel == null
                          ? TextStyle(fontSize: 15, color: cs.onSurfaceVariant)
                          : const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('shopTotal'),
                      style: TextStyle(
                          fontSize: 11, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 2),
                  Text('¥${_priceText(price)}',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFF4511E))),
                ],
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: (sel == null || _buying) ? null : () => _buy(sel),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(24)),
                  disabledBackgroundColor:
                      cs.onSurfaceVariant.withValues(alpha: 0.2),
                ),
                child: _buying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(t('shopBuyNow'),
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ===== 后台权益目录（2026-10-06 需求13，2026-10-06 改版：清单严格按后台配置渲染，
// 不再回退内置营销清单——后台没勾的权益不展示，避免「宣传了但不存在」的虚假权益）=====
// key 契约与 im-server internal/service/vip_perm.go 一致，勿改。
class _PermSpec {
  final String key;
  final IconData icon;
  // 2026-10-07 设计稿对齐：权益说明副标题（设计稿 .benefit .b-info .d）
  final String descKey;
  const _PermSpec(this.key, this.icon, this.descKey);
}

const List<_PermSpec> _permCatalog = [
  _PermSpec('badge', Icons.workspace_premium, 'vipPerkDescBadge'),
  _PermSpec('shopDiscount', Icons.sell, 'vipPerkDescDiscount'),
  _PermSpec('groupCreateLimit', Icons.groups, 'vipPerkDescGroupCreate'),
  _PermSpec('groupMemberLimit', Icons.group_add, 'vipPerkDescGroupMember'),
  _PermSpec('channelLimit', Icons.campaign, 'vipPerkDescChannel'),
  _PermSpec('sticker', Icons.sentiment_satisfied, 'vipPerkDescSticker'),
  _PermSpec('recallTime', Icons.history, 'vipPerkDescRecallTime'),
  _PermSpec('recallPeek', Icons.visibility, 'vipPerkDescRecallPeek'),
  // 2026-10-10 需求6：端到端加密权益（VIP 可手动开启，不受后台全局模式限制）
  _PermSpec('e2ee', Icons.lock_outline, 'vipPerkDescE2ee'),
];

/// key + 参数 → 展示文案（未勾选返回 null = 不渲染该行）
String? _permTitle(String Function(String, [Map<String, String>?]) t,
    String key, Map<String, num> perms) {
  if (!perms.containsKey(key)) return null;
  final n = perms[key]!.toDouble();
  String numText(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  switch (key) {
    case 'badge':
      return t('vipPerkBadge');
    case 'shopDiscount':
      return t('vipPerkShopDiscount', {'n': numText(n / 10)}); // 90 → 9 折
    case 'groupCreateLimit':
      return t('vipPerkGroupCreate', {'n': numText(n)});
    case 'groupMemberLimit':
      return t('vipPerkGroupMember', {'n': numText(n)});
    case 'channelLimit':
      return t('vipPerkChannel', {'n': numText(n)});
    case 'sticker':
      return t('vipPerkSticker');
    case 'recallTime':
      return t('vipPerkRecallTime', {'n': numText(n)});
    case 'recallPeek':
      return t('vipPerkRecallPeek');
    case 'e2ee': // 2026-10-10 需求6：端到端加密（无参数权益）
      return t('vipPerkE2ee');
    default:
      return null;
  }
}

/// VIP 会员购买页（2026-10-05；2026-10-06 按设计稿 vip.html 复刻 UI）：
/// hero 渐变卡 + VIP/SVIP 分层 tab + 包月/包年价格卡 + 权益清单 + 底部支付栏。
/// 价格/天数由后台配置（/vip/status 下发），余额购买，有效期内续费从当前到期日起叠加。
/// SVIP 价格读取后台预留键 svip_price_month/year（/vip/status 下发），购买链路
/// 未开放（按钮点击提示敬请期待），后续后端支持后接入。
class VipPage extends StatefulWidget {
  final VoidCallback? onBack;
  const VipPage({super.key, this.onBack});
  @override
  State<VipPage> createState() => _VipPageState();
}

class _VipPageState extends State<VipPage> {
  final _svc = ShopService.instance;

  bool _loading = true;
  bool _buying = false;
  // 2026-10-05 诊断增强：接口失败显式展示错误+重试，不伪装成「暂未开放购买」
  String? _error;
  // 2026-10-06 UI 改版：VIP/SVIP 双 tier + 包月/包年双档
  String _tier = 'vip'; // vip | svip
  double _priceMonth = 0;
  double _priceYear = 0;
  double _svipMonth = 0;
  double _svipYear = 0;
  // 后台配置的权益目录（2026-10-06 需求13）：空 = 未配置任何权益 → 回退内置营销清单
  Map<String, num> _vipPermsCfg = {};
  Map<String, num> _svipPermsCfg = {};
  String _plan = 'month';
  // 2026-10-06 开放 SVIP 购买：两档有效期各自独立存取（按当前 tier 取用）
  bool _vipActive = false;
  DateTime? _vipExpireAt;
  bool _svipActive = false;
  DateTime? _svipExpireAt;

  bool get _isSvip => _tier == 'svip';
  bool get _active => _isSvip ? _svipActive : _vipActive;
  DateTime? get _expireAt => _isSvip ? _svipExpireAt : _vipExpireAt;
  double get _planPrice => _isSvip
      ? (_plan == 'year' ? _svipYear : _svipMonth)
      : (_plan == 'year' ? _priceYear : _priceMonth);
  int get _planDays => _plan == 'year' ? 365 : 30;

  @override
  void initState() {
    super.initState();
    _load();
    _loadSelf(); // 2026-10-07 hero 头像/昵称（失败静默）
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _svc.vipStatus();
      if (!mounted) return;
      setState(() {
        _priceMonth = (data['priceMonth'] as num?)?.toDouble() ?? 0;
        _priceYear = (data['priceYear'] as num?)?.toDouble() ?? 0;
        _svipMonth = (data['svipPriceMonth'] as num?)?.toDouble() ?? 0;
        _svipYear = (data['svipPriceYear'] as num?)?.toDouble() ?? 0;
        // 权益目录（后台勾选+参数，见 im-server vip_perm.go）
        _vipPermsCfg =
            (data['vipPerms'] is Map) ? (data['vipPerms'] as Map).cast<String, num>() : {};
        _svipPermsCfg =
            (data['svipPerms'] is Map) ? (data['svipPerms'] as Map).cast<String, num>() : {};
        // 默认选中包月；包月未配置而包年已配置时自动落到包年
        if (_priceMonth <= 0 && _priceYear > 0) _plan = 'year';
        _vipActive = data['vipActive'] == true;
        _vipExpireAt = DateTime.tryParse('${data['vipExpireAt'] ?? ''}');
        _svipActive = data['svipActive'] == true;
        _svipExpireAt = DateTime.tryParse('${data['svipExpireAt'] ?? ''}');
        _loading = false;
      });
      // 权益缓存同步刷新（聊天撤回可见/徽标等处读取）
      await VipStore.instance.refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errText(e);
      });
    }
  }

  String _errText(Object e) => e.toString().replaceFirst('Exception: ', '');

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// tier 主题色：VIP 蓝 / SVIP 金
  Color get _tierColor => _isSvip ? const Color(0xFFC9A227) : AppTheme.primary;

  /// 2026-10-07 设计稿对齐：hero 区的当前用户头像/昵称（无全局 profile store，
  /// 页面内单独拉一次 /user/profile，失败静默降级为占位首字）
  String _selfName = '';
  String _selfAvatar = '';

  /// hero 圆形头像（40×40）
  /// 2026-10-07 修复：原先用 NetworkImage 直接加载，相对路径头像（AppConfig.assetUrl
  /// 能补 API 同域）会加载失败显示空白 —— 改用统一组件 AppAvatar（内部走
  /// AppConfig.assetUrl + 内置默认头像兜底，永不白块）。
  Widget _heroAvatar() {
    return AppAvatar(
      url: _selfAvatar,
      name: _selfName,
      size: 40,
      radius: 40 / 2,
      background: Colors.white.withValues(alpha: 0.25),
      emptyText: '·',
    );
  }

  /// 拉当前用户资料（仅用于 hero 展示，失败不打扰用户）
  Future<void> _loadSelf() async {
    try {
      final r = await ApiClient.instance.get('/api/v1/user/profile');
      final d = r.data?['data'];
      if (!mounted || d is! Map) return;
      setState(() {
        _selfName = (d['nickname'] ?? d['account'] ?? '').toString();
        _selfAvatar = (d['avatar'] ?? '').toString();
      });
    } catch (_) {
      // 静默：hero 头像昵称缺失不影响购买流程
    }
  }

  Future<void> _buy() async {
    if (_buying) return;
    final t = AppLocalizations.of(context).t;
    // 2026-10-06 开放 SVIP 购买：tier 随当前 tab 下发，后端按档位独立扣款/续期
    if (_planPrice <= 0) {
      AppDialogs.toast(context, t('vipNotConfigured'));
      return;
    }
    // 会员互斥（2026-10-10）：SVIP 有效期内 VIP tab 禁购（后端 1001 兜底同文案）
    if (!_isSvip && _svipActive) {
      AppDialogs.toast(context, t('vipSvipActiveMsg'));
      return;
    }
    final ok = await AppDialogs.confirm(
      context,
      title: t('vipBuy'),
      message: t('vipBuyConfirmMsg', {
        'price': _planPrice.toStringAsFixed(2),
        'days': '$_planDays',
      }),
      confirmText: t('vipBuy'),
    );
    if (ok != true || !mounted) return;
    setState(() => _buying = true);
    try {
      final data = await _svc.vipBuy(plan: _plan, tier: _tier);
      await WalletStore.instance.refresh();
      if (!mounted) return;
      setState(() {
        // 会员互斥（2026-10-10）：SVIP 升级折算会清掉 VIP（后端返回 vipActive=false），
        // 统一按返回体全量回填，不再按 tab 单侧写，避免 VIP 状态残留
        _vipActive = data['vipActive'] == true;
        _vipExpireAt = DateTime.tryParse('${data['vipExpireAt'] ?? ''}');
        _svipActive = data['svipActive'] == true;
        _svipExpireAt = DateTime.tryParse('${data['svipExpireAt'] ?? ''}');
      });
      AppDialogs.toast(context, t('vipBuySuccess'));
    } catch (e) {
      if (mounted) AppDialogs.toast(context, _errText(e));
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final cs = context.cs;
    return Scaffold(
      backgroundColor: context.setPageBg,
      body: Column(
        children: [
          V2SetHeader(
            title: t('vipTitle'),
            onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
            backSpec: V2SetBackSpec.chevron, // 2026-10-06 需求3：对齐设计稿细雪佛龙，与聊天页全 App 标准一致
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    // 2026-10-05 诊断增强：接口失败显式展示（如「VIP 购买未开启」
                    // = 后台 vip_enabled 未开；404/连接失败 = 服务器未更新新二进制）
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 32),
                              child: Text(_error!,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: cs.onSurfaceVariant)),
                            ),
                            const SizedBox(height: 14),
                            FilledButton.tonal(
                              onPressed: _load,
                              child: Text(t('wsRetry')),
                            ),
                          ],
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        children: [
                          _hero(t),
                          const SizedBox(height: 14),
                          _tierTabs(),
                          const SizedBox(height: 14),
                          // 2026-10-07：包月/包年两卡内容行数不同（包年多「折合价+原价线」）会不等高，
                          // 用 IntrinsicHeight 强制两卡等高。交叉轴必须用 stretch：
                          // start 会给 Stack 松高度约束导致等高失效（卡片高度由内容决定）。
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                    child: _planTile(
                                        t, 'month', t('vipPlanMonth'),
                                        _isSvip ? _svipMonth : _priceMonth)),
                                const SizedBox(width: 10),
                                Expanded(
                                    child: _planTile(
                                        t, 'year', t('vipPlanYear'),
                                        _isSvip ? _svipYear : _priceYear)),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          _perksSection(t, cs),
                        ],
                      ),
          ),
          _payBar(t, cs),
        ],
      ),
    );
  }

  /// hero 渐变卡（设计稿 .hero：右上装饰圆 + 标题 + 副标题 + 会员状态）
  Widget _hero(String Function(String, [Map<String, String>?]) t) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        // 2026-10-07：hero 主色跟随当前档位——VIP 蓝 / SVIP 金渐变
        // （用户反馈：切到 SVIP tab 时整张 hero 卡应换成 SVIP 配色）
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isSvip
              ? [const Color(0xFFF5C518), _kGold]
              : [
                  AppTheme.primary,
                  AppTheme.primary.withValues(alpha: 0.78),
                ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 右上装饰圆（设计稿 .hero::after）
          Positioned(
            right: -36,
            top: -36,
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 2026-10-07 设计稿对齐：hero-tag 半透明胶囊（星形 + 文案）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.auto_awesome,
                        color: Colors.white, size: 12),
                    const SizedBox(width: 4),
                    Text(t('vipHeroTag'),
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.white)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(t('vipHeroTitle'),
                  style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: Colors.white)),
              const SizedBox(height: 6),
              Text(t('vipHeroSub'),
                  style: TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      color: Colors.white.withValues(alpha: 0.92))),
              const SizedBox(height: 18),
              // 2026-10-07 设计稿对齐：hero-user 头像 + 昵称 + 当前状态
              Row(
                children: [
                  _heroAvatar(),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_selfName.isEmpty ? t('vipHeroGuest') : _selfName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white)),
                        const SizedBox(height: 2),
                        Text(
                          // 2026-10-10 需求2：有效期前缀区分档位——
                          // VIP 会员有效期至 xxx / SVIP会员有效期至 xxx
                          _active && _expireAt != null
                              ? t(_isSvip ? 'svipActiveUntil' : 'vipActiveUntil',
                                  {'date': _fmtDate(_expireAt!)})
                              : t('vipHeroCurrent'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.85)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// VIP/SVIP 分层 tab（设计稿 .tier-tabs：白卡分段，VIP 蓝填充 / SVIP 金渐变填充）
  Widget _tierTabs() {
    Widget tab(String tier, String label, IconData icon) {
      final active = _tier == tier;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tier = tier),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              gradient: active && tier == 'svip' ? _kGoldGradient : null,
              color: active && tier == 'vip' ? AppTheme.primary : null,
              borderRadius: BorderRadius.circular(9),
              boxShadow: active
                  ? [
                      BoxShadow(
                          color: (tier == 'svip'
                                  ? const Color(0xFFC9A227)
                                  : AppTheme.primary)
                              .withValues(alpha: 0.30),
                          blurRadius: 10,
                          offset: const Offset(0, 4)),
                    ]
                  : null,
            ),
            // 2026-10-07 设计稿对齐：tab 内前置皇冠/星形图标
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon,
                    size: 14,
                    color: active ? Colors.white : context.cs.onSurfaceVariant),
                const SizedBox(width: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: active ? Colors.white : null)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.cs.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 3,
              offset: const Offset(0, 1)),
        ],
      ),
      child: Row(
        children: [
          tab('vip', 'VIP', Icons.workspace_premium),
          tab('svip', 'SVIP', Icons.auto_awesome),
        ],
      ),
    );
  }

  /// 价格卡（设计稿 .plan：选中描边+浅底，大价格字；未配置置灰「暂未开放购买」）
  /// 2026-10-07 设计稿对齐：包年卡右上角「省X%」角标（按月价×12 与年价对比算出），
  /// 卡内补「折合 ¥x/月」+ 原价删除线（两档都配置才有意义）。
  Widget _planTile(String Function(String, [Map<String, String>?]) t,
      String plan, String label, double price) {
    final selected = _plan == plan;
    final disabled = price <= 0;
    final cs = context.cs;
    final accent = _tierColor;
    final monthPrice = _isSvip ? _svipMonth : _priceMonth;
    final yearPrice = _isSvip ? _svipYear : _priceYear;
    // 年付省多少：月价×12 为原价基准，>0 才算得出折扣
    final originYear = monthPrice * 12;
    final savePct = (plan == 'year' &&
            monthPrice > 0 &&
            yearPrice > 0 &&
            originYear > yearPrice)
        ? ((originYear - yearPrice) / originYear * 100).round()
        : 0;
    return GestureDetector(
      onTap: disabled ? null : () => setState(() => _plan = plan),
      // 2026-10-07 修复「省X%」角标不贴边：
      // 实测（截图像素）角标距右边 ~5px、距顶 ~26px，原因是角标被卡片
      // borderRadius(16) 的圆角**裁掉**了外侧部分，视觉上内缩。
      // 修法：角标移出圆角裁剪范围 —— 卡片本身只留内容 Stack，圆角角标由
      // 外层 Overflow + Positioned 直接贴到卡片右上角（top/right 用 -1 外溢）。
      // fit 必须expand：Stack 默认 loose 会把水平**松约束**传给卡片 Container，
      // 卡片无显式宽度 → 按内容宽度收缩（表现为两卡变窄、只剩内容区背景）。
      // 角标是 Positioned 子节点，不受 fit 影响。
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          // 卡片本体（圆角 + 描边 + 内容）
          Container(
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.08) : cs.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? accent
                    : cs.onSurfaceVariant.withValues(alpha: 0.18),
                width: selected ? 2 : 1,
              ),
            ),
            // IntrinsicHeight 已让两卡等高，这里直接铺满，内容垂直居中
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        height: 1.0,
                        color: disabled
                            ? cs.onSurfaceVariant.withValues(alpha: 0.5)
                            : cs.onSurfaceVariant)),
                const SizedBox(height: 6),
                Text(
                  disabled ? t('vipNotConfigured') : '¥${_priceText(price)}',
                  style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      height: 1.0,
                      color: disabled
                          ? cs.onSurfaceVariant.withValues(alpha: 0.5)
                          : cs.onSurface),
                ),
                if (!disabled) ...[
                  const SizedBox(height: 2),
                  Text(
                    '/ ${plan == 'year' ? t('vipPlanYear') : t('vipPlanMonth')}',
                    style: TextStyle(
                        fontSize: 11, height: 1.0, color: cs.onSurfaceVariant),
                  ),
                ],
                // 折合月价 + 原价删除线（仅包年且算出折扣时）
                if (savePct > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    t('vipPlanPerMonth',
                        {'price': _priceText(yearPrice / 12)}),
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.0,
                        fontWeight: FontWeight.w600,
                        color: _isSvip ? _kGold : AppTheme.primary),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    t('vipPlanOrigin',
                        {'price': _priceText(originYear)}),
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.0,
                        color: cs.onSurfaceVariant,
                        decoration: TextDecoration.lineThrough),
                  ),
                ],
                ],
              ),
            ),
          ),
          // 右上角「省X%」角标（设计稿 .plan .badge：右上圆角斜切）。
          // 放在**外层** Stack（卡片圆角裁剪之外），top/right = -1 真正贴住
          // 卡片右上角边框外沿；圆角与卡片一致，视觉上与卡片融为一角。
          if (savePct > 0)
            Positioned(
              top: -1,
              right: -1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  gradient: _isSvip ? _kGoldGradient : null,
                  color: _isSvip ? null : AppTheme.primary,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(14),
                    bottomLeft: Radius.circular(10),
                  ),
                ),
                child: Text(
                  t('vipPlanSave', {'pct': '$savePct'}),
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 权益清单（设计稿 .section-title + .benefits：竖条标题 + 图标方块行 + 对勾）。
  /// 2026-10-06 需求13 改版：严格渲染后台「会员设置」勾选的权益（含参数文案），
  /// 该档未配置任何权益时显示「敬请期待」占位——宣传与真实能力一致，不做营销假清单。
  Widget _perksSection(String Function(String, [Map<String, String>?]) t,
      ColorScheme cs) {
    final accent = _tierColor;
    final cfg = _isSvip ? _svipPermsCfg : _vipPermsCfg;
    // 组装行：icon + 标题（只渲染后台勾选的权益）
    final rows = <(IconData, String, String)>[];
    for (final s in _permCatalog) {
      final title = _permTitle(t, s.key, cfg);
      if (title != null) rows.add((s.icon, title, t(s.descKey)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(0, 8, 0, 10),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 14,
                decoration: BoxDecoration(
                    color: accent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Text(_isSvip ? t('vipPerksSvip') : t('vipPerksVip'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 3,
                  offset: const Offset(0, 1)),
            ],
          ),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: rows.isEmpty
              // 后台该档未勾选任何权益：显式占位，不渲染假清单
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 22),
                  child: Center(
                    child: Text(t('vipPerksEmpty'),
                        style: TextStyle(
                            fontSize: 13, color: cs.onSurfaceVariant)),
                  ),
                )
              : Column(
                  children: [
                    for (var i = 0; i < rows.length; i++)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          border: i == 0
                              ? null
                              : Border(
                                  top: BorderSide(
                                      color: cs.onSurfaceVariant
                                          .withValues(alpha: 0.10))),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: accent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(rows[i].$1, size: 18, color: accent),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(rows[i].$2,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                  // 2026-10-07 设计稿对齐：权益说明副标题
                                  const SizedBox(height: 2),
                                  Text(
                                    rows[i].$3,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 12,
                                        height: 1.25,
                                        color: cs.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                  color: accent, shape: BoxShape.circle),
                              child: const Icon(Icons.check,
                                  size: 12, color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  /// 底部支付栏（设计稿 .bottom-bar：应付金额 + 立即开通按钮，SVIP 金渐变）
  Widget _payBar(
      String Function(String, [Map<String, String>?]) t, ColorScheme cs) {
    final disabled = _planPrice <= 0;
    // 会员互斥（2026-10-10 需求1）：SVIP 有效期内 VIP tab 禁购置灰；
    // VIP 有效期内切到 SVIP tab 是「升级购买」（按剩余天数折算），按钮可点
    final vipBlocked = !_isSvip && _svipActive;
    final svipUpgrade = _isSvip && _vipActive;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
            top: BorderSide(
                color: cs.onSurfaceVariant.withValues(alpha: 0.12))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(t('vipPayLabel'),
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(
                      disabled
                          ? t('vipNotConfigured')
                          : '¥${_priceText(_planPrice)}',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: disabled
                              ? cs.onSurfaceVariant
                              : cs.onSurface),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: (_buying || vipBlocked) ? null : _buy,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 30, vertical: 13),
                  decoration: BoxDecoration(
                    gradient: _isSvip ? _kGoldGradient : null,
                    color: _isSvip
                        ? null
                        : ((disabled || vipBlocked)
                            ? cs.onSurfaceVariant.withValues(alpha: 0.3)
                            : AppTheme.primary),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: (disabled || vipBlocked)
                        ? null
                        : [
                            BoxShadow(
                                color: (_isSvip
                                        ? const Color(0xFFC9A227)
                                        : AppTheme.primary)
                                    .withValues(alpha: 0.35),
                                blurRadius: 14,
                                offset: const Offset(0, 6)),
                          ],
                  ),
                  child: _buying
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(
                          // 2026-10-10 需求1：SVIP 有效期禁购 VIP（置灰）；
                          // VIP 有效期买 SVIP 文案改「升级 SVIP」（差价折算）
                          vipBlocked
                              ? t('vipSvipActiveBtn')
                              : svipUpgrade
                                  ? t('vipUpgrade')
                                  : (_active ? t('vipRenew') : t('vipBuy')),
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
