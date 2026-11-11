import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一次「安装参数 / 拉起参数」的返回结果。
///
/// 原生侧统一成这个结构，Dart 侧就不用关心 Android (OpoData/OpoError) 与
/// iOS (OpoInstallData / NSError) 的差异。
class OpoInstallResult {
  const OpoInstallResult({
    required this.ok,
    this.bindData = '',
    this.channelCode = '',
    this.opid = '',
    this.errorCode = 0,
    this.errorMsg = '',
    this.shouldRetry = false,
  });

  /// 是否成功拿到数据对象（**不代表**一定带参数：自然安装也会 ok 但 bindData 为空）
  final bool ok;

  /// 动态参数原始串。Opo 是 JSON 字符串，如 `{"inviteCode":"AB12CD"}`
  final String bindData;

  /// 渠道编号
  final String channelCode;

  /// Opo 设备标识（全 0 表示 SDK 未激活成功）
  final String opid;

  /// 错误码（ok=false 时有意义）
  final int errorCode;

  /// 错误原文（SDK 返回的中文/英文说明）
  final String errorMsg;

  /// SDK 建议稍后重试（OpoError.shouldRetry()，错误码 -8）
  final bool shouldRetry;

  /// 是否值得重试：SDK 明确要求重试，或错误码是 -8
  bool get retryable => !ok && (shouldRetry || errorCode == -8);

  static OpoInstallResult fromMap(Object? raw) {
    if (raw is! Map) {
      return OpoInstallResult(
        ok: false,
        errorMsg: '原生返回了非 Map 数据: $raw',
      );
    }
    final m = Map<Object?, Object?>.from(raw);
    String str(String k) => (m[k] ?? '').toString();
    int num0(String k) => m[k] is num ? (m[k] as num).toInt() : 0;
    bool bool0(String k) => m[k] == true || m[k] == 'true';
    return OpoInstallResult(
      ok: m['ok'] == true,
      bindData: str('bindData'),
      channelCode: str('channelCode'),
      opid: str('opid'),
      errorCode: num0('errorCode'),
      errorMsg: str('errorMsg'),
      shouldRetry: bool0('shouldRetry'),
    );
  }

  @override
  String toString() => 'OpoInstallResult(ok: $ok, bindData: $bindData, '
      'channelCode: $channelCode, opid: $opid, errorCode: $errorCode, '
      'errorMsg: $errorMsg, shouldRetry: $shouldRetry)';
}

/// Opo（opoinstall）安装参数 / 一键拉起 的 Flutter 桥接。
///
/// **为什么是自己写的插件**：Opo 官方只发原生 SDK（Android jar + iOS
/// xcframework），没有 Flutter 插件（pub.dev 上搜 opoinstall 无结果，官网
/// 的 Flutter 标签页也没有真实 `.dart` 代码）。所以本项目在
/// `plugins/opo_install/` 下自带一层原生桥接，SDK 二进制随插件一起入库。
///
/// **与 openinstall（老版）的区别**（两套是不同产品，appKey 不通用）：
/// | | Opo | openinstall 老版 |
/// |---|---|---|
/// | Android 包名 | `com.opoinstall.api.OpoInstall` | `com.openinstall.*` |
/// | AndroidManifest 键 | `com.opoinstall.APP_KEY` | `com.openinstall.APP_KEY` |
/// | Info.plist 键 | `com.opoinstall.APP_KEY` | `com.openinstall.APP_KEY` |
class OpoInstall {
  OpoInstall._();

  static const MethodChannel _m = MethodChannel('im_app/opoinstall');

  static const EventChannel _wakeupEvent = EventChannel('im_app/opoinstall/wakeup');

  /// 当前平台是否有原生实现（Web 恒 false）。
  static bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 初始化 SDK（幂等，可多次调用）。
  ///
  /// [debug] 打开 SDK 内部日志；测试包还会关闭「模拟器检测」
  /// （Opo 默认在模拟器上拒绝工作，日志会打「您正在使用模拟器测试，将不会统计数据」，
  /// 排障时关掉它才能拿到真实错误码）。
  ///
  /// 返回 SDK 版本号（如 `2.1.0`）。
  static Future<String> initialize({bool debug = false}) async {
    final v = await _m.invokeMethod<String>('initialize', <String, Object?>{
      'debug': debug,
      'disableSimulatorCheck': debug,
    });
    return v ?? '';
  }

  /// SDK 版本号。
  static Future<String> getVersion() async =>
      (await _m.invokeMethod<String>('getVersion')) ?? '';

  /// Opo 设备标识（未激活成功时为全 0 串）。
  static Future<String> getOpId() async =>
      (await _m.invokeMethod<String>('getOpId')) ?? '';

  /// 必须在 Activity 就绪后调用，触发数据采集与服务器交互。
  static Future<void> start() async => _m.invokeMethod<void>('start');

  /// 上报注册事件（渠道统计用，业务失败可忽略）。
  static Future<void> reportRegister() async =>
      _m.invokeMethod<void>('register');

  /// 取安装参数（首装场景）。
  ///
  /// [timeoutSeconds] 为等待激活结果的时长；Opo 原生默认 10s。
  ///
  /// 失败时抛 [PlatformException] 的情况不应出现（原生一律转成
  /// `ok=false` 的结果对象），但调用方仍应 try/catch，避免插件缺失时崩溃。
  static Future<OpoInstallResult> getInstallParam({
    int timeoutSeconds = 10,
  }) async {
    final raw = await _m.invokeMethod<Object?>(
      'getInstallParam',
      <String, Object?>{'timeout': timeoutSeconds},
    );
    return OpoInstallResult.fromMap(raw);
  }

  /// 推送意图（Intent）交给 SDK 解析（Android 专用；iOS 由原生入口自动转发）。
  static Future<OpoInstallResult> handleDeepLink() async {
    final raw = await _m.invokeMethod<Object?>('handleDeepLink');
    return OpoInstallResult.fromMap(raw);
  }

  /// 拉起回调流（App 已安装、点推广链接被 scheme / Universal Link 拉起时）。
  ///
  /// 冷启动时原生会把结果缓存，订阅后立即补发一次。
  static Stream<OpoInstallResult> get wakeupStream => _wakeupEvent
      .receiveBroadcastStream()
      .map((e) => OpoInstallResult.fromMap(e));
}
