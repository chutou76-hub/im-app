import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 功能开关（后台「系统配置 → 功能开关」配置，经 /auth/config 下发）。
/// 默认全开：后台未配置时不应影响现有功能。
class FeatureFlags {
  FeatureFlags._();
  static final FeatureFlags instance = FeatureFlags._();

  /// 是否开启零钱（关闭 → 聊天窗口不显示红包/转账入口、用户中心不显示我的钱包）
  final ValueNotifier<bool> walletOn = ValueNotifier<bool>(true);

  /// 是否开启邀请码（2026-09-22 需求3 合并：改读「邀请码注册」inviteCodeOn，
  /// 后台原 invite_feature_enabled 开关废弃）。
  /// 关闭 → 注册页无邀请码输入框、游客直接进入、用户中心不显示我的邀请码
  final ValueNotifier<bool> inviteOn = ValueNotifier<bool>(true);

  /// 是否开启小助手（2026-09-22 需求2，sys_config assistant_enabled 默认 true）
  /// 关闭 → 通讯录不显示小助手入口（注册不自动添加由服务端短路）
  final ValueNotifier<bool> assistantOn = ValueNotifier<bool>(true);

  /// 是否开启频道（2026-09-22 需求2，sys_config channel_enabled 默认 true）
  /// 关闭 → 消息页「+」面板隐藏「新建频道」入口（注册自动关注由服务端短路）
  final ValueNotifier<bool> channelOn = ValueNotifier<bool>(true);

  /// 是否开启靓号商城（2026-10-05，sys_config shop_enabled 默认 false）
  /// 关闭 → 我的页隐藏「靓号商城」入口（购买接口服务端也会 4016 拒绝）
  final ValueNotifier<bool> shopOn = ValueNotifier<bool>(false);

  /// 是否开启 VIP 会员购买（2026-10-05，sys_config vip_enabled 默认 false）
  /// 关闭 → 我的页隐藏「VIP 会员」入口（购买接口服务端也会 4017 拒绝）
  final ValueNotifier<bool> vipOn = ValueNotifier<bool>(false);

  /// 是否开启图形验证码（2026-11-02 需求5：sys_config captcha_enabled）。
  /// 开启 → 账号密码注册、绑定手机发码均需图形验证码（前置校验）。
  /// 默认 false（后台未配置/老服务端未下发该字段时不影响现有功能）。
  final ValueNotifier<bool> captchaOn = ValueNotifier<bool>(false);

  /// VIP 双档价格（2026-10-05 需求改版：包月/包年分别定价；/auth/config 随开关下发。
  /// 购买页实际价格以 /vip/status 为准，这里仅作展示兜底）
  final ValueNotifier<double> vipPriceMonth = ValueNotifier<double>(0);
  final ValueNotifier<double> vipPriceYear = ValueNotifier<double>(0);

  bool _loaded = false;

  /// 拉取一次配置（缓存生效；force=true 强制刷新）。
  /// 失败静默：保持上次/默认值，不打扰用户。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final j = r.data['data'];
      if (j is Map) {
        // 需求5：图形验证码开关（/auth/config 已返回 captchaOn）。
        captchaOn.value = j['captchaOn'] == true || j['captchaOn'] == 'true';
        walletOn.value = j['walletOn'] != false && j['walletOn'] != 'false';
        // 需求3 合并：邀请码展示开关 = 注册开关（inviteCodeOn）
        inviteOn.value =
            j['inviteCodeOn'] != false && j['inviteCodeOn'] != 'false';
        assistantOn.value =
            j['assistantOn'] != false && j['assistantOn'] != 'false';
        channelOn.value =
            j['channelOn'] != false && j['channelOn'] != 'false';
        // 商城/会员（2026-10-05）：默认关（与后端 sys_config 默认值一致）
        shopOn.value = j['shopOn'] == true || j['shopOn'] == 'true';
        vipOn.value = j['vipOn'] == true || j['vipOn'] == 'true';
        vipPriceMonth.value =
            (double.tryParse('${j['vipPriceMonth'] ?? 0}') ?? 0).toDouble();
        vipPriceYear.value =
            (double.tryParse('${j['vipPriceYear'] ?? 0}') ?? 0).toDouble();
        _loaded = true;
      }
    } catch (_) {
      // 网络异常时保持默认值
    }
  }
}
