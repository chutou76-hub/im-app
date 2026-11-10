import 'api_client.dart';

/// 靓号商城 / VIP 会员（2026-10-05）
/// 对应后端 /shop/shortids、/shop/shortids/:id/buy、/vip/status、/vip/buy。
/// 信封 code!=0 统一抛 Exception(服务端 message)（本类内显式检查，
/// 与 ApiClient 其他手写接口同口径）；开关关闭时后端返回 4016/4017，
/// message 为友好文案，页面直接 toast 即可。
class ShopService {
  ShopService._();
  static final ShopService instance = ShopService._();

  final _api = ApiClient.instance;

  /// 统一信封校验：code!=0 抛 Exception(message)，成功返回 data
  Map<String, dynamic> _ok(dynamic resp) {
    final body = (resp.data as Map<String, dynamic>?)
            ?.cast<String, dynamic>() ??
        {};
    if ((body['code'] as int? ?? -1) != 0) {
      throw Exception((body['message'] ?? '请求失败').toString());
    }
    return (body['data'] as Map<String, dynamic>?) ?? {};
  }

  /// 商城货架：分页 + 关键字搜索 + 类型过滤（2026-10-06 UI 改版）。
  /// 返回 {total,page,size,list:[{id,shortId,type,remark,price}]}
  Future<Map<String, dynamic>> listShortIds({
    int page = 1,
    int size = 20,
    String keyword = '',
    int type = 0,
  }) async {
    final r = await _api.get('/api/v1/shop/shortids', query: {
      'page': page,
      'size': size,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (type > 0) 'type': type,
    });
    return _ok(r);
  }

  /// 购买靓号（余额扣款 + 绑定）。返回 {shortId, balance}
  Future<Map<String, dynamic>> buyShortId(int id) async {
    final r = await _api.post('/api/v1/shop/shortids/$id/buy');
    return _ok(r);
  }

  /// 会员状态 + 配置。返回 {price,days,vipExpireAt,vipActive,balance}
  Future<Map<String, dynamic>> vipStatus() async {
    final r = await _api.get('/api/v1/vip/status');
    return _ok(r);
  }

  /// 购买/续费会员（2026-10-05 需求改版：包月/包年双档）。
  /// [plan] month=包月(30天) / year=包年(365天)
  /// [tier] vip|svip（2026-10-06 开放 SVIP 购买链路）；
  /// 返回按档位区分：vip → {vipExpireAt, vipActive, balance}，svip → {svipExpireAt, ...}
  Future<Map<String, dynamic>> vipBuy(
      {String plan = 'month', String tier = 'vip'}) async {
    final r =
        await _api.post('/api/v1/vip/buy', data: {'plan': plan, 'tier': tier});
    return _ok(r);
  }
}
