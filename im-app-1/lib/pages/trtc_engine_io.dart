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
            break;
          case TRTCCloudListener.onUserVideoAvailable:
            // 官方流程：远端视频流可用（available=true）时才调用 startRemoteView，
            // 否则即使进房也拿不到画面（视频通话"只显示自己"的根因）
            final uid = params['userId']?.toString() ?? '';
            final available = params['available'] == true;
            debugPrint(
                '[TRTC] user video available: uid=$uid available=$available');
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
              onRemoteUserLeft?.call(uid);
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
      return null;
    } catch (e) {
      CallDebugLog.instance.log('enterRoom EXCEPTION: $e');
      return AppLocalizations.instance.t('trtcInitFailed', {'err': '$e'});
    }
  }

  /// 2026-11-01：进房失败时清理半初始化的 SDK 实例——不清理的话下一通
  /// enterRoom 会因设备/实例占用异常（官方文档：exitRoom 回调前禁止再次 enterRoom）
  Future<void> _safeExitRoom(TRTCCloud cloud) async {
    try { await cloud.stopLocalAudio(); } catch (_) {}
    try { await cloud.exitRoom(); } catch (_) {}
    try { await TRTCCloud.destroySharedInstance(); } catch (_) {}
    if (identical(_cloud, cloud)) _cloud = null;
  }

  @override
  Future<void> exitRoom() async {
    CallDebugLog.instance.log('exitRoom (inRoom=$_inRoom)');
    _videoAvailable.clear();
    _remoteViewIds.clear();
    if (_cloud != null && _inRoom) {
      try {
        await _cloud!.stopLocalAudio();
        await _cloud!.exitRoom();
      } catch (_) {}
      _inRoom = false;
    }
    if (_cloud != null) {
      TRTCCloud.destroySharedInstance();
      _cloud = null;
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
        if (_localViewId == null) return;
        await _cloud?.startLocalPreview(true, _localViewId);
      } else {
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
        onViewCreated(id);
      },
    );
  }

  @override
  Widget remoteVideoView(
      {required String userId, required ValueChanged<int> onViewCreated}) {
    return TRTCCloudVideoView(
      onViewCreated: (id) {
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
    try {
      await _cloud?.startLocalPreview(true, viewId);
    } catch (_) {}
  }

  @override
  Future<void> startRemoteView(String userId, int viewId) async {
    _remoteViewIds[userId] = viewId;
    try {
      await _cloud?.startRemoteView(
        userId,
        TRTCCloudDef.TRTC_VIDEO_STREAM_TYPE_BIG,
        viewId,
      );
    } catch (_) {}
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
