import 'api_client.dart';
import '../l10n/app_locale.dart';

/// 朋友圈 / 钱包接口封装
class MomentService {
  MomentService._();
  static final MomentService instance = MomentService._();
  final _api = ApiClient.instance;

  /// 朋友圈时间线：{total, list:[{id,userId,senderName,senderAvatar,assistant,images,likeCount,liked,hidden,mine,content,createdAt}]}
  /// scope：0=广场（所有用户） / 1=好友（仅好友动态，2026-11-07 需求6） /
  /// 2=同城（按城市过滤，2026-11-10 朋友圈三 tab 改版）
  /// [city]：同城城市名（市全名，如「北京市」，与发帖侧高德口径一致），
  /// 仅 scope=2 生效，非空才下发 query（老服务端/其他 scope 行为不变）
  Future<Map<String, dynamic>> list(
      {int page = 1,
      int size = 20,
      int scope = 0,
      String city = '',
      // 2026-11-13 朋友圈内容搜索：keyword 非空时服务端在当前 scope 可见性
      // 基础上叠加 content LIKE 过滤
      String keyword = ''}) async {
    final r = await _api.get('/api/v1/moments', query: {
      'page': page,
      'size': size,
      'scope': scope,
      if (city.isNotEmpty) 'city': city,
      if (keyword.isNotEmpty) 'keyword': keyword,
    });
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 查看指定用户的朋友圈（好友资料页入口）：GET /api/v1/moments/:ownerId
  Future<Map<String, dynamic>> listByUser(String ownerId,
      {int page = 1, int size = 20}) async {
    final r = await _api
        .get('/api/v1/moments/$ownerId', query: {'page': page, 'size': size});
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 发布朋友圈（2026-11-07 需求3 加 videos 参数）
  /// [videos]：[{url, thumb, duration(秒)}]，与图片互斥（客户端保证）；
  /// 服务端 moments_review_enabled 开启时帖子进入待审核。
  Future<void> publish(String content, List<String> images,
      {List<Map<String, dynamic>> videos = const [],
      String province = '',
      String city = '',
      String district = ''}) async {
    await _api.post('/api/v1/moments', data: {
      'content': content,
      'images': images,
      'videos': videos,
      'province': province,
      'city': city,
      'district': district,
    });
  }

  /// 默认所在地（2026-11-07 朋友圈地区需求）：GET /api/v1/moments/location
  /// 服务端按请求 IP 归属地（ip2region 离线库）解析；
  /// 返回 {province, city, district, custom}，custom=后台「地区自定义」开关
  Future<Map<String, dynamic>> location() async {
    final r = await _api.get('/api/v1/moments/location');
    return (((r.data['data'] as Map<String, dynamic>?) ?? {}));
  }

  /// 点赞 / 取消（toggle），返回点赞后状态
  Future<bool> like(String postId) async {
    final r = await _api.post('/api/v1/moments/$postId/like');
    return (((r.data['data'] as Map<String, dynamic>?) ?? {})['liked'] == true);
  }

  /// 发表评论：POST /api/v1/moments/:id/comment，body {content, replyToId}
  /// replyToId > 0 = 回复某条评论（2026-11-07 需求4）
  /// 成功返回服务端评论数据 {ID, PostID, UserID, Content, CreatedAt}
  Future<Map<String, dynamic>> comment(String postId, String content,
      {int replyToId = 0}) async {
    final r = await _api.post('/api/v1/moments/$postId/comment',
        data: {'content': content, 'replyToId': replyToId});
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'comment failed').toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 删除自己的朋友圈动态：DELETE /api/v1/moments/post/:pid（2026-11-07 需求2）
  Future<void> deletePost(String postId) async {
    final r = await _api.delete('/api/v1/moments/post/$postId');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'delete failed').toString());
    }
  }

  /// 互动通知列表（2026-11-07 需求3）：GET /api/v1/moment-notify/list
  Future<List<Map<String, dynamic>>> notifyList() async {
    final r = await _api.get('/api/v1/moment-notify/list');
    final body = r.data as Map<String, dynamic>? ?? {};
    if ((body['code'] as num?)?.toInt() != 0) return [];
    return (((body['data'] as Map?)?['list'] as List<dynamic>?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
  }

  // ===== 2026-11-07 需求1：付费添加好友 =====

  /// 付费添加报价：GET /api/v1/friend/paid-add/calc?targetId=
  /// {price, free, platformRate, platformAmount, ownerAmount, alipayEnabled, balance}
  Future<Map<String, dynamic>> paidAddCalc(String targetId) async {
    final r = await _api
        .get('/api/v1/friend/paid-add/calc', query: {'targetId': targetId});
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'calc failed').toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 付费添加：POST /api/v1/friend/paid-add
  /// method=1 余额（需 payPwd，即时通过）/ 2 支付宝凭证（proofImage，待审核）
  /// 2026-11-07（夜10）修复「付款提示参数错误」：服务端 targetId 为 int64，
  /// App 原来直接传字符串（"targetId":"123"）JSON 绑定失败——转成数字再发。
  Future<void> paidAdd(String targetId,
      {int method = 1, String payPwd = '', String proofImage = ''}) async {
    final tid = int.tryParse(targetId);
    if (tid == null || tid <= 0) {
      throw Exception('invalid targetId');
    }
    final r = await _api.post('/api/v1/friend/paid-add', data: {
      'targetId': tid,
      'method': method,
      'payPwd': payPwd,
      'proofImage': proofImage,
    });
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'paid add failed').toString());
    }
  }

  /// 设置自己的被添加好友价格（元，0=免费走普通申请）：PUT /api/v1/user/friend-add-price
  Future<void> setFriendAddPrice(double price) async {
    final r = await _api
        .put('/api/v1/user/friend-add-price', data: {'price': price});
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'save failed').toString());
    }
  }

  /// 删除自己的评论：DELETE /api/v1/moments/comment/:cid
  /// （服务端仅允许删除自己的评论，他人评论会返回业务错误）
  Future<void> deleteComment(String commentId) async {
    final r = await _api.delete('/api/v1/moments/comment/$commentId');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception((body['message'] ?? 'delete comment failed').toString());
    }
  }

  // ===== 2026-10-10 需求3：朋友圈互动通知（评论/点赞红点）=====

  /// 未读互动通知数：GET /api/v1/moment-notify/unread → data.count
  /// 2026-11-13 需求：顺带返回 data.total（含已读的通知总数）——
  /// 朋友圈页在 total=0（一条互动通知都没有）时隐藏「互动通知」入口卡。
  /// 返回 {unread, total}
  Future<Map<String, int>> notifyUnread() async {
    final r = await _api.get('/api/v1/moment-notify/unread');
    final data = (r.data['data'] as Map<String, dynamic>? ?? {});
    return {
      'unread': (data['count'] as num?)?.toInt() ?? 0,
      'total': (data['total'] as num?)?.toInt() ?? 0,
    };
  }

  /// 全部置已读（进入朋友圈页时调用）：POST /api/v1/moment-notify/read
  Future<void> notifyRead() async {
    await _api.post('/api/v1/moment-notify/read');
  }

  /// 我的钱包：{balance, records:[{id,type,typeName,amount,balance,title,createdAt}]}
  Future<Map<String, dynamic>> wallet() async {
    final r = await _api.get('/api/v1/wallet/me');
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 领取红包（后端结算冻结资金并分配）：返回详情 + myAmount
  /// 业务错误（已领完 / 已过期退回 / 旧数据）必须抛出来，
  /// 否则会拿着空 data 显示「拆到 ¥0」——以前就是这么骗人的。
  Future<Map<String, dynamic>> redPacketClaim(String msgId) async {
    final r = await _api.post('/api/v1/wallet/redpacket/$msgId/claim');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception(
          (body['message'] ?? AppLocalizations.instance.t('svcClaimFailed'))
              .toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 红包领取详情：{senderName,note,mode,totalAmount,count,claimedCnt,status,expireAt,list:[...]}
  Future<Map<String, dynamic>> redPacketDetail(String msgId) async {
    final r = await _api.get('/api/v1/wallet/redpacket/$msgId');
    final body = r.data as Map<String, dynamic>? ?? {};
    final code = (body['code'] as num?)?.toInt() ?? 0;
    if (code != 0) {
      throw Exception(
          (body['message'] ?? AppLocalizations.instance.t('svcQueryFailed'))
              .toString());
    }
    return ((body['data'] as Map<String, dynamic>?) ?? {});
  }

  /// 账单：时间筛选 + 分页 {total, list}
  Future<Map<String, dynamic>> records({
    String? start,
    String? end,
    int page = 1,
    int size = 20,
  }) async {
    final r = await _api.get('/api/v1/wallet/records', query: {
      if (start != null && start.isNotEmpty) 'start': start,
      if (end != null && end.isNotEmpty) 'end': end,
      'page': page,
      'size': size,
    });
    return ((r.data['data'] as Map<String, dynamic>?) ?? {});
  }
}
