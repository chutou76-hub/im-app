import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tencent_trtc_cloud/tencent_trtc_cloud.dart';

import 'trtc_engine.dart';
import '../l10n/app_locale.dart';
import '../utils/call_debug_log.dart';

/// native 实现：腾讯云 TRTC 官方 Flutter 插件（SDK 2.9.x API）
/// 群通话：远端成员按 userId 管理（多远端），不再只跟踪单个人
class TrtcEngineImpl implements TrtcEngine {
  TRTCCloud? _cloud;
  bool _inRoom = false;
  int? _localViewId;

  /// 2026-11-11 修复「有声音、没画面」：用户在本地视图创建之前点了开摄像头
  /// （或进房时视图还没建好），旧实现直接静默 return 且不记任何标记，摄像头
  /// 就一直不开、对端也永远收不到我们的视频流。这里记住意图，视图/房间就绪
  /// 后补开一次。
  bool _pendingPreview = false;

  /// 远端成员：userId -> 视频流是否可用（onUserVideoAvailable 驱动）
  final Set<String> _videoAvailable = {};

  /// 远端成员：userId -> 已绑定的渲染 viewId（视图先建、流后到，双向就绪即绑定）
  final Map<String, int> _remoteViewIds = {};

  @override
  ValueChanged<String>? onRemoteUserEntered;

  @override
  ValueChanged<String>? onRemoteUserLeft;

  @override
  bool get isReal => true;

  @override
  Future<String?> enterRoom({
    required int sdkAppId,
    required String userId,
    required String userSig,
    required int roomId,
    required bool isVideo,
    dynamic localView,
    dynamic remoteView,
  }) async {
    try {
      CallDebugLog.instance.log(
          'enterRoom start sdkAppId=$sdkAppId userId=$userId roomId=$roomId isVideo=$isVideo sigLen=${userSig.length} nowMs=${DateTime.now().millisecondsSinceEpoch ~/ 1000}');
      final cloud = await TRTCCloud.sharedInstance();
      if (cloud == null) {
        CallDebugLog.instance.log('enterRoom FAIL sharedInstance=null');
        return AppLocalizations.instance.t('trtcInitNoInstance');
      }
      _cloud = cloud;
      // 2026-11-01 修复「两端互见全空」：enterRoom 的 await 只代表调用提交，
      // 真正成败由 onEnterRoom(result) 回调通知（result<0 = 进房失败）。此前
      // 不检查回调直接置 _inRoom=true → App 显示已接通但实际不在房间 → PC 端
      // 收不到任何流（stream-added 都没有）、App 端也看不到对方。
      final enterResult = Completer<int>();
      cloud.registerListener((type, params) {
        switch (type) {
          case TRTCCloudListener.onEnterRoom:
            final r = params is num
                ? params.toInt()
                : ((params is Map ? params['result'] : null) as num?)?.toInt() ?? -1;
            debugPrint('[TRTC] onEnterRoom result=$r');
            CallDebugLog.instance.log('onEnterRoom result=$r');
            if (!enterResult.isCompleted) enterResult.complete(r);
            break;
          case TRTCCloudListener.onError:
            // 2026-11-01 排障埋点：-3301 等进房失败的 errMsg 就在这里
            // （userSig 校验失败/过期、参数非法等原因 SDK 会在此回调给出确切说明）
            if (params is Map) {
              final ec = params['errCode'];
              final em = params['errMsg']?.toString() ?? '';
              debugPrint('[TRTC] onError code=$ec msg=$em');
              CallDebugLog.instance.log('SDK onError code=$ec msg=$em');
            }
            break;
          case TRTCCloudListener.onRemoteUserEnterRoom:
            final uid = params['userId']?.toString() ?? '';
            debugPrint('[TRTC] remote user enter: $params');
            // 2026-11-11 排障：对端是否真的在房间里（与"有没有推视频流"分开看）
            CallDebugLog.instance.log('remote user enter uid=$uid');
            break;
          case TRTCCloudListener.onUserVideoAvailable:
            // 官方流程：远端视频流可用（available=true）时才调用 startRemoteView，
            // 否则即使进房也拿不到画面（视频通话"只显示自己"的根因）
            final uid = params['userId']?.toString() ?? '';
            final available = params['available'] == true;
            debugPrint(
                '[TRTC] user video available: uid=$uid available=$available');
            // 2026-11-11 排障：这行是「对方到底有没有推视频」的唯一判据——缺失
            // 说明对端根本没开摄像头，问题在对端采集，不在本端渲染。
            CallDebugLog.instance
                .log('userVideoAvailable uid=$uid available=$available');
            if (uid.isEmpty) break;
            if (available) {
              _videoAvailable.add(uid);
              onRemoteUserEntered?.call(uid);
              final viewId = _remoteViewIds[uid];
              if (viewId != null) startRemoteView(uid, viewId);
            } else {
              _videoAvailable.remove(uid);
              final viewId = _remoteViewIds[uid];
              if (viewId != null) stopRemoteView(uid);
              // 2026-11-12 修复「手动关闭摄像头会自动挂断通话」：视频流不可用
              // ≠ 用户离房——对端关摄像头（stopLocalPreview）只会收到
              // available=false，旧代码在这里调 onRemoteUserLeft，被
              // CallService 当成「对端掉线」走 _onPeerMediaGone → 800ms 后
              // 自动发 hangup 把通话挂断。用户真正离房由下方
              // onRemoteUserLeaveRoom 分支负责，此处只停渲染。
            }
            break;
          case TRTCCloudListener.onRemoteUserLeaveRoom:
            final uid = params['userId']?.toString() ?? '';
            if (uid.isNotEmpty) {
              _videoAvailable.remove(uid);
              _remoteViewIds.remove(uid);
              onRemoteUserLeft?.call(uid);
            }
            debugPrint('[TRTC] remote user leave: $params');
            break;
          case TRTCCloudListener.onFirstVideoFrame:
            // 2026-11-11 排障：首帧到达 = 渲染链路真正通了（userId 为空表示本地）
            final fuid =
                params is Map ? (params['userId']?.toString() ?? '') : '';
            CallDebugLog.instance
                .log('firstVideoFrame uid=${fuid.isEmpty ? 'local' : fuid}');
            debugPrint('[TRTC] first video frame: $params');
            break;
          default:
            break;
        }
      });
      // 进房参数
      final params = TRTCParams(
        sdkAppId: sdkAppId,
        userId: userId,
        userSig: userSig,
        roomId: roomId,
        role: TRTCCloudDef.TRTCRoleAnchor,
      );
      // 2.9.x：enterRoom(param, scene)，scene 传视频/音频通话场景
      final scene = isVideo
          ? TRTCCloudDef.TRTC_APP_SCENE_VIDEOCALL
          : TRTCCloudDef.TRTC_APP_SCENE_AUDIOCALL;
      await cloud.enterRoom(params, scene);
      CallDebugLog.instance.log('enterRoom() submitted, waiting onEnterRoom...');
      // 2026-11-01：等 onEnterRoom 回调确认真正进房（8s 超时按失败处理，
      // 错误码 -9999=超时未回调）；失败时把错误码带给调用方显示，
      // 不再假成功留在「已接通」状态。
      final r = await enterResult.future
          .timeout(const Duration(seconds: 8), onTimeout: () => -9999);
      if (r < 0) {
        CallDebugLog.instance.log('enterRoom FAILED code=$r → cleanup+report');
        await _safeExitRoom(cloud);
        return AppLocalizations.instance
            .t('trtcInitFailed', {'err': 'enterRoom code:$r'});
      }
      _inRoom = true;
      CallDebugLog.instance.log('enterRoom OK, starting local audio');
      // 采集音频（默认音质）
      await cloud.startLocalAudio(TRTCCloudDef.TRTC_AUDIO_QUALITY_DEFAULT);
      CallDebugLog.instance.log('startLocalAudio ok');
      // 视频通话：若调用方已传入本地 viewId，则直接开启预览。
      // 采集失败（无摄像头/权限被拒）不挂掉进房：继续留在房里收对方画面与声音
      if (isVideo && localView is int) {
        _localViewId = localView;
        try {
          await cloud.startLocalPreview(true, localView);
          CallDebugLog.instance.log('startLocalPreview ok');
        } catch (e) {
          debugPrint('[TRTC] 本地摄像头采集失败（降级为仅接收）: $e');
          CallDebugLog.instance.log('startLocalPreview FAIL: $e');
        }
      }
      // 2026-11-11：进房前已点开摄像头（视图还没创建，setCameraOn 只记了意图）
      // → 房间与视图都就绪了，这里补开预览，否则摄像头永远不开、对端无画面。
      CallDebugLog.instance.log(
          'enterRoom done isVideo=$isVideo localViewId=$_localViewId pendingPreview=$_pendingPreview');
      if (isVideo && localView is! int && _pendingPreview && _localViewId != null) {
        await startLocalPreview(_localViewId!);
      }
      return null;
    } catch (e) {
      CallDebugLog.instance.log('enterRoom EXCEPTION: $e');
      return AppLocalizations.instance.t('trtcInitFailed', {'err': '$e'});
    }
  }

  /// 2026-11-01：进房失败时清理半初始化的 SDK 实例——不清理的话下一通
  /// enterRoom 会因设备/实例占用异常（官方文档：exitRoom 回调前禁止再次 enterRoom）。
  /// 2026-11-11：补等 onExitRoom 回调再销毁（同 exitRoom 修复，iOS AudioUnit 释放）。
  Future<void> _safeExitRoom(TRTCCloud cloud) async {
    final exited = Completer<int>();
    cloud.registerListener((type, params) {
      if (type == TRTCCloudListener.onExitRoom && !exited.isCompleted) {
        exited.complete(params is num ? params.toInt() : 0);
      }
    });
    try { await cloud.stopLocalAudio(); } catch (_) {}
    try { await cloud.exitRoom(); } catch (_) {}
    try {
      await exited.future.timeout(const Duration(seconds: 3), onTimeout: () => -1);
    } catch (_) {}
    try { await TRTCCloud.destroySharedInstance(); } catch (_) {}
    if (identical(_cloud, cloud)) _cloud = null;
  }

  @override
  Future<void> exitRoom() async {
    CallDebugLog.instance.log('exitRoom (inRoom=$_inRoom)');
    _videoAvailable.clear();
    _remoteViewIds.clear();
    // 2026-11-11：退房后本地视图随之销毁，viewId 必须失效——否则下一通在
    // 新视图创建前会用旧 viewId 开预览，画面挂到一个已销毁的渲染器上，
    // 表现为「摄像头开了但自己和对端都看不到」。
    _localViewId = null;
    _pendingPreview = false;
    if (_cloud != null) {
      // 2026-11-11 修复「挂断后对方还有声音」（iOS 实锤）：
      // 1) 去掉 _inRoom 守卫——只要实例还在就完整退房。此前状态标志不对时
      //    整个 stopLocalAudio/exitRoom 被跳过，麦克风持续推流，对端一直有声。
      // 2) 官方要求：exitRoom 必须等 onExitRoom 回调返回后才能销毁实例。
      //    此前 await exitRoom()（仅代表调用提交）后立即 destroySharedInstance，
      //    iOS 端 AudioUnit 未释放——通话界面关了声音还在推。现在用 Completer
      //    等 onExitRoom（3s 超时兜底），再停采集、销毁实例。
      final cloud = _cloud!;
      final exited = Completer<int>();
      // 先补挂监听（进房时已挂过，重复挂幂等），确保能收到退出回调
      cloud.registerListener((type, params) {
        if (type == TRTCCloudListener.onExitRoom &&
            !exited.isCompleted) {
          final r = params is num ? params.toInt() : 0;
          exited.complete(r);
        }
      });
      try {
        await cloud.exitRoom();
      } catch (_) {}
      try {
        await exited.future
            .timeout(const Duration(seconds: 3), onTimeout: () => -1);
      } catch (_) {}
      CallDebugLog.instance.log('onExitRoom received, stopping audio/destroy');
      try {
        await cloud.stopLocalAudio();
      } catch (_) {}
      try {
        await cloud.stopLocalPreview();
      } catch (_) {}
      try {
        await TRTCCloud.destroySharedInstance();
      } catch (_) {}
      _inRoom = false;
      if (identical(_cloud, cloud)) _cloud = null;
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _cloud?.muteLocalAudio(muted);
    } catch (_) {}
  }

  @override
  Future<void> setSpeaker(bool on) async {
    // 2.9.x：扬声器切换走设备管理器（int 常量）
    try {
      final dev = _cloud?.getDeviceManager();
      if (dev != null) {
        await dev.setAudioRoute(on
            ? TRTCCloudDef.TRTC_AUDIO_ROUTE_SPEAKER
            : TRTCCloudDef.TRTC_AUDIO_ROUTE_EARPIECE);
      }
    } catch (_) {}
  }

  @override
  Future<void> setCameraOn(bool on) async {
    try {
      if (on) {
        // 必须有业务层设置的小窗 viewId，否则 startLocalPreview(null) 会全屏渲染本地画面
        if (_localViewId == null) {
          // 2026-11-11：视图还没创建就静默 return 会让摄像头永远不开——
          // 记住意图，视图创建/进房后补开（见 localVideoView / enterRoom）。
          _pendingPreview = true;
          CallDebugLog.instance.log('cameraOn deferred (no local view yet)');
          return;
        }
        _pendingPreview = true;
        CallDebugLog.instance
            .log('cameraOn startLocalPreview viewId=$_localViewId cloud=${_cloud != null}');
        await _cloud?.startLocalPreview(true, _localViewId);
      } else {
        _pendingPreview = false;
        await _cloud?.stopLocalPreview();
      }
    } catch (_) {}
  }

  @override
  Future<void> switchCamera() async {
    try {
      final dev = _cloud?.getDeviceManager();
      if (dev != null) await dev.switchCamera(false);
    } catch (_) {}
  }

  @override
  Widget localVideoView({required ValueChanged<int> onViewCreated}) {
    return TRTCCloudVideoView(
      onViewCreated: (id) {
        _localViewId = id;
        // 2026-11-11 排障 + 自愈：本地视图创建此前完全没有日志，无法区分
        // 「视图没建起来（渲染层）」与「视图建了但没开预览（采集层）」。
        // 已在房间时直接开预览，不再依赖业务层回调时序。
        CallDebugLog.instance.log(
            'localVideoView created viewId=$id inRoom=$_inRoom pendingPreview=$_pendingPreview');
        onViewCreated(id);
        if (_inRoom && _cloud != null) startLocalPreview(id);
      },
    );
  }

  @override
  Widget remoteVideoView(
      {required String userId, required ValueChanged<int> onViewCreated}) {
    return TRTCCloudVideoView(
      onViewCreated: (id) {
        // 2026-11-11 排障：平台视图创建成功与否是「有声无画面」的关键分界——
        // 没有这行日志就无法区分「视图没建起来（渲染层）」与「视图建了但没帧（流层）」。
        CallDebugLog.instance.log(
            'remoteVideoView created uid=$userId viewId=$id videoAvailable=${_videoAvailable.contains(userId)}');
        _remoteViewIds[userId] = id;
        onViewCreated(id);
        // 若该成员视频流已可用，立即绑定画面
        if (_videoAvailable.contains(userId)) {
          startRemoteView(userId, id);
        }
      },
    );
  }

  @override
  Future<void> startLocalPreview(int viewId) async {
    _localViewId = viewId;
    // 2026-11-11 排障：本地预览失败此前静默吞掉（iOS 相机权限被拒/无设备时
    // 只表现为「看不到人」，日志无痕）。记录调用与结果。
    CallDebugLog.instance.log('startLocalPreview viewId=$viewId');
    final cloud = _cloud;
    if (cloud == null) {
      // 2026-11-11：旧实现用 `_cloud?.` 空安全调用后照样打 "OK"——日志骗人，
      // 实际什么都没做，摄像头根本没开、对端永远收不到视频。改为显式跳过并
      // 记下意图，等房间就绪后补开。
      _pendingPreview = true;
      CallDebugLog.instance.log('startLocalPreview SKIP cloud=null (deferred)');
      return;
    }
    try {
      await cloud.startLocalPreview(true, viewId);
      _pendingPreview = true;
      CallDebugLog.instance.log('startLocalPreview OK viewId=$viewId');
    } catch (e) {
      CallDebugLog.instance.log('startLocalPreview FAIL err=$e');
    }
  }

  @override
  Future<void> startRemoteView(String userId, int viewId) async {
    _remoteViewIds[userId] = viewId;
    // 2026-11-11 排障：startRemoteView 失败此前被 catch(_) 静默吞掉——iOS 上
    // 「有声无画面」若发生在绑定这一步，日志里完全看不到任何痕迹。改为记录
    // 调用与结果（含异常），通话页点状态文字即可捞出。
    CallDebugLog.instance.log('startRemoteView uid=$userId viewId=$viewId');
    final cloud = _cloud;
    if (cloud == null) {
      // 2026-11-11：同 startLocalPreview——`_cloud?.` 空安全调用后照样打 OK 是
      // 假日志（旧监听器残留时最容易误导排查），显式跳过。
      CallDebugLog.instance.log('startRemoteView SKIP cloud=null uid=$userId');
      return;
    }
    try {
      await cloud.startRemoteView(
        userId,
        TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG,
        viewId,
      );
      CallDebugLog.instance.log('startRemoteView OK uid=$userId');
    } catch (e) {
      CallDebugLog.instance.log('startRemoteView FAIL uid=$userId err=$e');
    }
  }

  @override
  Future<void> stopRemoteView(String userId) async {
    try {
      await _cloud?.stopRemoteView(
        userId,
        TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG,
      );
    } catch (_) {}
  }
}
