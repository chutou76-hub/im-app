import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:opo_install/opo_install.dart';

import 'feature_flags.dart';

/// 免填邀请码（携带参数安装 / 一键拉起）。
///
/// 演进史（每次换的都是**不同产品**，不是改个包名就能复用）：
///   Xinstall → openinstall（老版）→ **Opo（opoinstall.com，2026-11-11 定稿）**
///
/// 为什么必须换到 Opo：客户账号在 `developer.opoinstall.com`，落地页是
/// `opopage.com`、web SDK 是 `res.opoinstalljs.com/opo-<appKey>.js`，全是 Opo
/// 体系；而 `openinstall_flutter_plugin` 内置老版 SDK 3.1.0
/// （`com.openinstall.*`），两者后端不互通 —— 老版 SDK 拿 Opo 的 appKey 去校验，
/// 必然返回「appKey错误，请登陆 openinstall 查看应用配置」→ `INIT_ERROR`。
///
/// 取值链路（Opo）：
///   1. 用户打开我们的 H5 落地页（服务端 `GET /api/v1/dl?inviteCode=xxx`），
///      页面里的 `OpoInstall.parseUrlParams()` 把参数与设备指纹上报给 Opo；
///   2. 用户装好 App 首次打开 → `getInstallParam` 拿回 `bindData`
///      （JSON 字符串，如 `{"inviteCode":"AB12CD"}`）；
///   3. 已安装用户点链接被拉起 → 走拉起回调（Android: handleDeepLink /
///      registerDeepLinkCallback；iOS: SceneDelegate 转发 universal link / scheme）。
///
/// 全链路静默降级：后台没开 / Web 端 / 原生插件缺失 → 跳过或吞异常，
/// **绝不影响 App 启动**；拿不到码时注册页输入框保持原样。
class OpenInstallService {
  OpenInstallService._();

  static final OpenInstallService instance = OpenInstallService._();

  /// 本地存储键：待消费的邀请码
  static const String _kCodeKey = 'openinstall_invite_code';

  /// 本地存储键：邀请码是否已被使用过（'1' = 已用）
  static const String _kUsedKey = 'openinstall_invite_code_used';

  /// 通用 KV：与 AppSettings 同一套（FlutterSecureStorage），不引入新依赖
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  /// 调试日志开关（编译期注入，默认关）。
  /// 打开方式：flutter build apk --dart-define=OPENINSTALL_DEBUG=true
  /// 打开后：① 打开 SDK 内部日志并关闭模拟器检测；② 记录诊断流水，App 启动
  /// 后自动弹出可复制的诊断框（见 [diagnostics]）。
  static const bool _verbose = bool.fromEnvironment('OPENINSTALL_DEBUG');

  /// 防止重复初始化（main() 与页面可能各调一次）
  bool _inited = false;

  /// install 重试次数（SDK 要求重试时用，最多 2 次）
  int _retry = 0;

  /// 拉起回调订阅（长期驻留，App 运行中被拉起也要能收到）
  StreamSubscription<OpoInstallResult>? _wakeupSub;

  /// SDK 版本号（OpoInstall.getVersion()，诊断用）
  String _sdkVersion = '';

  /// 设备标识（全 0 表示 SDK 未激活成功 —— 这是「拿不到参数」最强的信号）
  String _opid = '';

  /// 内存态待用邀请码（ValueNotifier 便于注册页监听；也可直接读 getter）
  final ValueNotifier<String> pendingInviteCodeNotifier =
      ValueNotifier<String>('');

  /// 是否已经尝试过初始化（无论成功/跳过/异常），便于排障
  bool get inited => _inited;

  // ==================== 诊断 ====================

  /// 是否开启了诊断模式（编译期 OPENINSTALL_DEBUG）。
  bool get verboseEnabled => _verbose;

  /// 诊断流水（仅诊断模式记录，正式包不占内存）
  final List<String> _diag = <String>[];

  /// 时钟原点：日志时间戳用「启动后 +x.xxs」，比绝对时间更好对齐
  final DateTime _boot = DateTime.now();

  /// 流水有更新时自增，弹窗监听它刷新内容
  final ValueNotifier<int> diagRevision = ValueNotifier<int>(0);

  /// 流程"落定"信号：已取到码 / 明确没取到 / 跳过 / 异常。
  /// 注意：SDK 要求重试时**不**落定，因为马上会重试。
  final Completer<void> _settled = Completer<void>();

  /// 最近一次结果的一句话结论（会随重试结果更新）
  String _outcome = '未开始（正在等 SDK 回调）';

  Future<void> get settled => _settled.future;
  bool get isSettled => _settled.isCompleted;

  /// 结果结论，供弹窗显示
  String get outcome => _outcome;

  void _markSettled(String outcome) {
    // 先更新结论再判完成：重试后拿到码时，结论要能覆盖"未取到"
    _outcome = outcome;
    if (!_settled.isCompleted) _settled.complete();
    _touch();
  }

  void _touch() {
    if (!_verbose) return;
    diagRevision.value++;
  }

  /// 统一日志出口：debugPrint（adb / Xcode 可看）+ 诊断流水（App 内可看）
  void _log(String msg) {
    debugPrint('[Opo] $msg');
    if (!_verbose) return;
    final ms = DateTime.now().difference(_boot).inMilliseconds;
    _diag.add('+${(ms / 1000).toStringAsFixed(2)}s  $msg');
    // 防内存膨胀：重试/多次回调也不会超过 300 行
    if (_diag.length > 300) _diag.removeAt(0);
    diagRevision.value++;
  }

  /// 生成一份可直接复制的诊断报告。
  /// 用户在 App 弹窗里点「复制全部」把这段发给开发，即可定位卡在哪一步，
  /// 不需要连电脑跑 adb。
  String diagnostics() {
    final b = StringBuffer();
    b.writeln('===== Opo 免填邀请码 诊断报告 =====');
    b.writeln('时间: ${_fmtTime(DateTime.now())}');
    b.writeln('平台: ${kIsWeb ? "web" : defaultTargetPlatform.name}');
    b.writeln('诊断模式: ${_verbose ? "开（OPENINSTALL_DEBUG=true）" : "关"}');
    b.writeln('');
    b.writeln('[SDK]');
    b.writeln('  版本     = ${_sdkVersion.isEmpty ? "(未初始化)" : _sdkVersion}');
    b.writeln('  opid     = ${_opid.isEmpty ? "(空)" : _opid}'
        '${_opid.replaceAll("0", "").isEmpty && _opid.isNotEmpty ? "  ← 全 0，说明 SDK 未激活成功" : ""}');
    b.writeln('');
    b.writeln('[配置]');
    b.writeln('  免填开关 openinstallEnabled = '
        '${FeatureFlags.instance.openinstallEnabled.value}');
    b.writeln('  参数名   openinstallParamKey = $_paramKey');
    b.writeln('  推广链接 openinstallPromoUrl = '
        '"${FeatureFlags.instance.openinstallPromoUrl.value}"（空 = 用默认 /api/v1/dl）');
    b.writeln('');
    b.writeln('[状态]');
    b.writeln('  inited   = $_inited');
    b.writeln('  settled  = ${_settled.isCompleted}');
    b.writeln('  outcome  = $_outcome');
    b.writeln('  内存待用码 = "${pendingInviteCodeNotifier.value}"');
    b.writeln('');
    b.writeln('[流水]');
    if (_diag.isEmpty) {
      b.writeln('  (空——若「诊断模式」显示为关，说明装的不是诊断包)');
    } else {
      for (final l in _diag) {
        b.writeln('  $l');
      }
    }
    b.writeln('');
    b.writeln('===== 报告结束 =====');
    return b.toString();
  }

  static String _fmtTime(DateTime t) {
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} '
        '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
  }

  // ==================== 初始化 ====================

  /// 初始化并取回首装 / 拉起参数。可多次调用（幂等）。
  ///
  /// 任何异常都在内部吞掉——SDK 缺失 / 平台不支持 / 网络异常都不能影响启动。
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    _log('init 开始');
    // ① 先恢复本地未消费的邀请码（纯本地、无网络），保证注册页哪怕在
    //    离线/秒开场景下也能拿到上次留下的邀请码
    await hydrate();
    // ② Web 端没有原生实现，直接跳过
    if (!OpoInstall.isSupported) {
      _log('当前平台无原生实现（${kIsWeb ? "web" : defaultTargetPlatform.name}），跳过');
      _markSettled('跳过：当前平台无原生实现');
      return;
    }
    try {
      // ③ 功能开关由 /auth/config 下发；main() 调用本方法时页面还没拉过配置
      //    （默认 false 会直接跳过）→ 这里主动拉一次（带缓存，失败静默）。
      await FeatureFlags.instance.load();
      var enabled = FeatureFlags.instance.openinstallEnabled.value;
      if (!enabled) {
        // 冷启动首帧网络没就绪、或服务端短暂 5xx 时，FeatureFlags.load()
        // 会静默吞异常并保留默认值 false —— 表现和「后台真没开开关」完全一样，
        // 首装用户会因此白丢一次归因机会。这里延迟 1.2s 强刷一次再判。
        _log('首次拉到 enabled=false，1.2s 后强刷配置再判');
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        await FeatureFlags.instance.load(force: true);
        enabled = FeatureFlags.instance.openinstallEnabled.value;
        _log('重试拉取配置后 enabled=$enabled');
      }
      _log('状态: enabled=$enabled, paramKey=$_paramKey, '
          'promoUrl=${FeatureFlags.instance.openinstallPromoUrl.value}'
          '（appKey 由原生 manifest / Info.plist 注入，Dart 不可见）');
      if (!enabled) {
        _log('后台未开启免填邀请码，跳过');
        _markSettled('跳过：后台开关 openinstallEnabled=false');
        return;
      }
      // 注意：**不用**「推广链接为空」当作跳过条件 —— 链接指向我们自己的
      // 落地页（服务端有默认值），appKey 是原生编译期注入的，与链接无关。
      _log('开始接线（initialize + start + install）');
      // ④ MethodChannel 调用在原生未注册时抛的是**异步** MissingPluginException，
      //    普通 try/catch 抓不到 → 用 runZonedGuarded 兜住，绝不冒泡到全局。
      await runZonedGuarded<Future<void>>(
        () async {
          _sdkVersion = await OpoInstall.initialize(debug: _verbose);
          _log('SDK 初始化完成，版本=$_sdkVersion');
          await OpoInstall.start();
          _log('已调用 start（触发采集与服务器交互）');

          // 拉起回调（App 已安装、被 scheme / universal link 唤起）
          _wakeupSub?.cancel();
          _wakeupSub = OpoInstall.wakeupStream.listen(
            _onWakeup,
            onError: (Object e) => _log('拉起回调流异常: $e'),
          );
          _log('已订阅拉起回调');

          // 首装参数（SDK 内部等激活结果，最多 timeout 秒）
          final r = await OpoInstall.getInstallParam(timeoutSeconds: 10);
          await _onInstall(r);
        },
        (e, s) {
          _log('async error: $e');
          _markSettled('异常（异步）：$e');
        },
      );
    } catch (e) {
      // 同步异常（MissingPluginException / UnsupportedError / 原生未配置 …）
      _log('init skipped: $e');
      _markSettled('异常（同步）：$e');
    }
  }

  /// 拉起回调（App 已安装场景）
  Future<void> _onWakeup(OpoInstallResult r) async {
    await _onResult(r, tag: 'wakeup');
  }

  /// 首装参数回调（未安装 → 装完首次打开）。
  /// SDK 说可重试时（错误码 -8 / shouldRetry），3 秒后重试，最多 2 次。
  Future<void> _onInstall(OpoInstallResult r) async {
    await _onResult(r, tag: 'install');
    if (r.retryable && _retry < 2) {
      _retry++;
      _log('SDK 要求重试，第 $_retry 次重试（3s 后）');
      Timer(const Duration(seconds: 3), () async {
        try {
          final again = await OpoInstall.getInstallParam(timeoutSeconds: 10);
          await _onInstall(again);
        } catch (e) {
          _log('retry failed: $e');
        }
      });
    }
  }

  /// 解析回调：拿到邀请码 → 落本地 + 更新内存待用值。
  /// 同一次安装可能被回调多次（拉起与首装都会触发），已被使用过的情况下
  /// 不再写入，避免重复注册复用旧码。
  Future<void> _onResult(OpoInstallResult r, {required String tag}) async {
    try {
      // 顺手刷新 opid（诊断关键：全 0 = 未激活）
      try {
        _opid = await OpoInstall.getOpId();
      } catch (_) {}

      _log('$tag 回调: ok=${r.ok} bindData="${r.bindData}" '
          'channelCode="${r.channelCode}" opid="$_opid" '
          'errorCode=${r.errorCode} errorMsg="${r.errorMsg}" '
          'shouldRetry=${r.shouldRetry}');

      final code = _pick(r);
      if (code.isEmpty) {
        // 空数据的典型原因（按概率从高到低）：
        //   ① 覆盖安装 / 非首装：设备早有安装记录，SDK 不再做安装归因
        //   ② 落地页不是在**这台手机**上打开的（电脑开页面 + 手机装包）
        //   ③ 控制台应用信息（Android 包名 com.siqu.chat / 签名）与包不一致
        //   ④ 模拟器：Opo 默认不统计模拟器设备
        _log('$tag 没取到邀请码，原因排查：是否覆盖安装 / 页面是否本机打开 / '
            '控制台包名是否 com.siqu.chat / 是否模拟器');
        if (tag == 'install') {
          if (r.retryable) {
            _touch(); // 还会自动重试 → 先不落定，弹窗保持"检测中"
          } else {
            _markSettled('未取到邀请码（install 已回调，但没有参数）：'
                '${r.errorMsg.isEmpty ? "bindData 为空" : r.errorMsg}');
          }
        } else {
          // 拉起拿到空数据不代表最终结果（首装以 install 为准）
          _touch();
        }
        return;
      }
      _log('取到邀请码: $code');
      _markSettled('已取到邀请码: $code');
      // 已被使用过 → 不再写回（防「注册完又点推广链接」把自己当新人）
      if (await _isUsed()) {
        _log('该邀请码已被使用过，不再写回');
        return;
      }
      pendingInviteCodeNotifier.value = code;
      try {
        await _storage.write(key: _kCodeKey, value: code);
        await _storage.write(key: _kUsedKey, value: '0');
        _log('已写入本地待用邀请码');
      } catch (e) {
        // 落盘失败不影响本次使用（内存值仍在）
        _log('persist failed: $e');
      }
    } catch (e) {
      _log('onResult failed: $e');
      _markSettled('解析异常：$e');
    }
  }

  /// URL 参数名（后台可配，默认 inviteCode）
  String get _paramKey {
    final k = FeatureFlags.instance.openinstallParamKey.value.trim();
    return k.isEmpty ? 'inviteCode' : k;
  }

  /// 从结果里取邀请码。`bindData` 是 **JSON 字符串**，不同接入方式还有几种变体，
  /// 按可能性从高到低依次尝试：
  ///   ① `{"inviteCode":"AB12CD"}`   —— web SDK parseUrlParams 的标准产物
  ///   ② `"inviteCode=AB12CD"`       —— 手工拼 query 串
  ///   ③ `"AB12CD"`                  —— 直接把邀请码当纯值传
  ///   ④ 顶层平铺（少数版本）
  String _pick(OpoInstallResult r) {
    final raw = r.bindData.trim();
    if (raw.isNotEmpty) {
      // ① JSON 对象（含少数把参数套在 data 字段里的接入）
      if (raw.startsWith('{')) {
        try {
          final dec = jsonDecode(raw);
          if (dec is Map) {
            final v = dec[_paramKey]?.toString().trim() ?? '';
            if (v.isNotEmpty) return v;
            final nested = dec['data'];
            if (nested is Map) {
              final v2 = nested[_paramKey]?.toString().trim() ?? '';
              if (v2.isNotEmpty) return v2;
            }
          }
        } catch (e) {
          _log('bindData JSON 解析失败: $e');
        }
      }
      // ② query 串形式
      if (raw.contains('=') && !raw.startsWith('{')) {
        try {
          final q = Uri.splitQueryString(raw);
          final v = q[_paramKey]?.trim() ?? '';
          if (v.isNotEmpty) return v;
        } catch (_) {}
      }
      // ③ 纯值：长度合理且不含明显结构字符才认，避免把渠道串当邀请码
      if (!raw.startsWith('{') && !raw.contains('=') && !raw.contains('&') &&
          raw.length <= 64) {
        return raw;
      }
    }
    return '';
  }

  Future<bool> _isUsed() async {
    try {
      final v = await _storage.read(key: _kUsedKey);
      return v == '1';
    } catch (_) {
      return false;
    }
  }

  /// 待用邀请码：内存值优先（同步返回，注册页 initState 里直接读）。
  /// 本地读取由 [hydrate] 预热：init() 结束时内存值已就绪。
  String get pendingInviteCode => pendingInviteCodeNotifier.value.trim();

  /// 冷启动预热：从本地恢复上次未消费的邀请码（内存为空时调用）。
  Future<void> hydrate() async {
    if (pendingInviteCodeNotifier.value.trim().isNotEmpty) return;
    try {
      if (await _isUsed()) return;
      final code = (await _storage.read(key: _kCodeKey))?.trim() ?? '';
      if (code.isNotEmpty) {
        pendingInviteCodeNotifier.value = code;
        _log('从本地恢复待用邀请码: $code');
      }
    } catch (e) {
      _log('hydrate failed: $e');
    }
  }

  /// 注册成功 / 已携带邀请码提交后调用：清内存 + 本地，并标记已使用，
  /// 避免下次注册（同设备换账号）复用旧邀请码。
  /// 同时上报注册事件（渠道统计用，失败不影响业务）。
  Future<void> consume() async {
    pendingInviteCodeNotifier.value = '';
    try {
      await _storage.delete(key: _kCodeKey);
      await _storage.write(key: _kUsedKey, value: '1');
    } catch (e) {
      debugPrint('[Opo] consume failed: $e');
    }
    reportRegister();
  }

  /// 上报注册事件（渠道统计）。静默失败：统计丢一次不算业务问题。
  void reportRegister() {
    if (!OpoInstall.isSupported) return;
    OpoInstall.reportRegister().catchError((Object e) {
      debugPrint('[Opo] reportRegister failed: $e');
    });
  }
}
