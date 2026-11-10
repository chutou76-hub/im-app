import 'shop_service.dart';

/// 会员权益缓存（2026-10-06 需求13）。
///
/// 后端 /vip/status 的 `perms` = 当前用户**实际生效**的权益对象
/// （SVIP 有效 → svip_perms，VIP 有效 → vip_perms，均无效为空对象），
/// key 契约见 im-server internal/service/vip_perm.go：
///   badge / shopDiscount / groupCreateLimit / groupMemberLimit /
///   channelLimit / sticker / recallTime / recallPeek
///
/// 缓存时机：我的页进入（me_page，vipOn 开启时）与 VIP 页加载成功后刷新；
/// 没刷到时权益视为空（对应功能回落默认行为，不影响使用）。
class VipStore {
  VipStore._();
  static final VipStore instance = VipStore._();

  Map<String, num> _perms = {};
  bool vipActive = false;
  bool svipActive = false;
  bool _loading = false;

  /// 「查看撤回消息」权益（永久可查看撤回原文）
  bool get canPeekRecall => _perms.containsKey('recallPeek');

  /// 「VIP 专属标识」权益
  bool get hasBadge => _perms.containsKey('badge');

  /// 「撤回时间延长」权益分钟数（未配置返回 null = 默认 2 分钟）
  int? get recallMinutes =>
      _perms.containsKey('recallTime') ? (_perms['recallTime']!.toInt()) : null;

  /// 生效权益原始表（只读拷贝）
  Map<String, num> get perms => Map.unmodifiable(_perms);

  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final data = await ShopService.instance.vipStatus();
      vipActive = data['vipActive'] == true;
      svipActive = data['svipActive'] == true;
      final p = data['perms'];
      _perms = (p is Map) ? (p as Map).cast<String, num>() : {};
    } catch (_) {
      // 拉取失败保持旧值（未开关 vip_enabled 时接口 4017，权益视为空）
    } finally {
      _loading = false;
    }
  }
}
