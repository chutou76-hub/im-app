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

  /// 邀请码模式（2026-11-11 需求1，/auth/config 下发 inviteMode）：
  /// universal=全民邀请码（每个用户有独立邀请码）→ 用户中心入口为
  /// 「邀请推广中心」二级页（推广总金额+邀请好友列表）；
  /// designated=指定邀请码（默认）→ 维持原「我的邀请码」点击复制。
  final ValueNotifier<bool> inviteUniversal = ValueNotifier<bool>(false);

  /// App 下载地址（2026-11-11 需求，sys_config app_download_url，/auth/config
  /// 下发 appDownloadUrl）：App 端「邀请好友」「邀请朋友」点击复制该网址分享。
  /// 空 = 后台未配置 → 复制时提示未配置。
  final ValueNotifier<String> appDownloadUrl = ValueNotifier<String>('');

  /// 推广二维码图片 URL（2026-11-11 需求2，sys_config promo_qrcode_url，
  /// /auth/config 下发 promoQrcodeUrl）：后台上传，App 端推广中心
  /// 「保存推广二维码」/ 编辑资料「邀请朋友」下载该图片存入相册。
  /// 空 = 后台未配置 → 保存时提示未配置。
  final ValueNotifier<String> promoQrcodeUrl = ValueNotifier<String>('');

  /// 是否开启 OpenInstall 免填邀请码（2026-11-11：由 Xinstall 更换为 OpenInstall，
  /// sys_config openinstall_enabled，/auth/config 下发 openinstallEnabled）：
  /// 开启 → App 启动时初始化 OpenInstall SDK，首装/被拉起时取回 bindData
  /// （JSON 字符串，内含 inviteCode）自动填入注册页。
  /// 默认 false（后台未配置/老服务端未下发该字段时不影响现有注册流程）。
  final ValueNotifier<bool> openinstallEnabled = ValueNotifier<bool>(false);

  /// OpenInstall 推广落地页地址（2026-11-11，sys_config openinstall_promo_url，
  /// /auth/config 下发 openinstallPromoUrl）。注意：这是**我们自己的 H5 落地页**
  /// （GET /api/v1/dl），不是 OpenInstall 控制台链接。仅用于展示/排障，
  /// **不再作为「是否初始化 SDK」的判据**——AppKey 是原生注入的，与链接无关。
  final ValueNotifier<String> openinstallPromoUrl = ValueNotifier<String>('');

  /// OpenInstall URL 参数名（2026-11-11，sys_config openinstall_param_key，
  /// /auth/config 下发 openinstallParamKey）：默认 inviteCode，需与落地页拼的键一致。
  final ValueNotifier<String> openinstallParamKey =
      ValueNotifier<String>('inviteCode');

  /// 推广素材海报底图 URL（2026-11-11 需求，sys_config promo_poster_url，
  /// /auth/config 下发 promoPosterUrl）：后台上传，推广中心海报合成的背景图。
  /// 空 = 后台未配置 → 海报回退纯色渐变底。
  final ValueNotifier<String> promoPosterUrl = ValueNotifier<String>('');

  // 推广素材海报「二维码落位」三参数（2026-11-11 需求，百分比 0~100）：
  //   promoQrX    —— 二维码**中心**横坐标占底图宽度的百分比
  //   promoQrY    —— 二维码**中心**纵坐标占底图高度的百分比
  //   promoQrSize —— 二维码边长占底图**宽度**的百分比
  // 默认值与服务端 defPromoQr* 完全一致（对齐官方 3:4 素材 1086×1448 的白框：
  // 内白区 (403,965)-(682,1248)）。后台可改，换素材不必发版。
  /// 二维码中心 X（%）
  final ValueNotifier<double> promoQrX = ValueNotifier<double>(49.95);

  /// 二维码中心 Y（%）
  final ValueNotifier<double> promoQrY = ValueNotifier<double>(76.44);

  /// 二维码边长（占底图宽度 %）
  final ValueNotifier<double> promoQrSize = ValueNotifier<double>(25.78);

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
        // 2026-11-11 需求1：邀请码模式（universal=全民邀请码）
        inviteUniversal.value = '${j['inviteMode'] ?? ''}' == 'universal';
        // 2026-11-11 需求：App 下载地址（「邀请好友」「邀请朋友」复制分享）
        appDownloadUrl.value = '${j['appDownloadUrl'] ?? ''}';
        promoQrcodeUrl.value = '${j['promoQrcodeUrl'] ?? ''}';
        // 2026-11-11：OpenInstall 免填邀请码 + 推广素材海报底图
        openinstallEnabled.value =
            j['openinstallEnabled'] == true || j['openinstallEnabled'] == 'true';
        openinstallPromoUrl.value = '${j['openinstallPromoUrl'] ?? ''}';
        final paramKey = '${j['openinstallParamKey'] ?? ''}'.trim();
        openinstallParamKey.value =
            paramKey.isEmpty ? 'inviteCode' : paramKey;
        promoPosterUrl.value = '${j['promoPosterUrl'] ?? ''}';
        // 二维码落位三参数（2026-11-11）：缺字段/解析失败 → 保留内置默认值，
        // 不把 0 当"未配置"（0 是合法的贴边坐标）
        promoQrX.value = _pct(j['promoQrX'], 49.95, 0, 100);
        promoQrY.value = _pct(j['promoQrY'], 76.44, 0, 100);
        promoQrSize.value = _pct(j['promoQrSize'], 25.78, 5, 100);
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

  /// 解析百分比配置（2026-11-11 需求：推广海报二维码落位）。
  /// 语义：字段缺失 / 非数字 → 返回 [def]；有值则夹到 [lo, hi]。
  /// 不用 `?? def` 直接取值的原因：0 是合法坐标（贴左/贴顶），不能被当成"未配置"。
  static double _pct(Object? raw, double def, double lo, double hi) {
    if (raw == null) return def;
    final v = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (v == null || v.isNaN || v.isInfinite) return def;
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
  }
}
