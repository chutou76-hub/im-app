import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/call_media.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../services/user_cache.dart';
import '../theme/app_theme.dart';
import '../utils/call_debug_log.dart';
import '../utils/call_permissions.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';

/// 视频通话页（单聊）：远端视频大画面 + 中央对方姓名标签 + 底部按钮栏 + 自己小窗。
/// 媒体引擎按后台 call_engine 选择（TRTC / WebRTC），页面不感知差异。
/// 群组通话走 GroupCallPage。
class VideoCallPage extends StatefulWidget {
  final String peerName;
  final String peerAvatar;
  final String? convId; // 会话 ID（房间号）
  const VideoCallPage(
      {super.key, required this.peerName, this.peerAvatar = '', this.convId});

  @override
  State<VideoCallPage> createState() => _VideoCallPageState();
}

class _VideoCallPageState extends State<VideoCallPage> {
  bool _muted = false;
  bool _cameraOff = false;
  bool _hasCamera = true; // 本端是否有可用摄像头（权限被拒/无设备 → 头像占位降级）
  bool _flipCam = false;
  bool _swapped = false; // 大小窗互换：false=大窗对方/小窗自己，true=大窗自己/小窗对方
  bool _connecting = true;
  String _status = '正在连接…';
  StreamSubscription<CallEvent>? _sub;
  // 2026-11-13 通话浮窗需求：媒体引擎与通话计时上移 CallService——
  // 页面不再自建 CallMedia / 计时器，收起为浮窗（pop 路由）不再挂断媒体。

  bool _enteredRoom = false;
  bool _engineReady = false; // 引擎可用（TRTC 已配置 / WebRTC 有 ICE）
  bool _prepared = false; // 配置是否已拉取完成
  bool _pendingAccept = false; // 配置未就绪时先收到的 accept
  bool _ringStarted = false; // 主叫回铃音是否已启动

  String? _remoteUserId;

  /// 取本地化文案（未挂载时回退为 key，避免访问失效 context）
  String _t(String key, [Map<String, String>? params]) =>
      mounted ? AppLocalizations.of(context).t(key, params) : key;

  @override
  void initState() {
    super.initState();
    // 2026-11-01 排障：通话页点状态文字可复制全量日志（CallDebugLog）
    CallDebugLog.instance.clear();
    CallDebugLog.instance.log(
        'VideoCallPage open conv=${widget.convId} myId=${CallService.instance.myId} hasSig=${CallService.instance.config?.trtcSig.isNotEmpty == true}');
    _sub = CallService.instance.events.listen(_onCallEvent);
    // 2026-11-13 通话浮窗需求：远端用户由 CallService.remotePeerId 通知
    //（媒体引擎归服务层持有，页面只监听渲染）
    _remoteUserId = CallService.instance.remotePeerId.value;
    CallService.instance.remotePeerId.addListener(_onRemotePeerChanged);
    _prepare();
  }

  /// 2026-11-13 通话浮窗需求：远端用户变化（onRemoteJoined/Left 在服务层触发）
  void _onRemotePeerChanged() {
    if (!mounted) return;
    setState(() => _remoteUserId = CallService.instance.remotePeerId.value);
  }

  /// 订阅信令事件：accept → 进房；reject/hangup/cancel → 结束
  void _onCallEvent(CallEvent e) {
    if (e.convId != widget.convId) return;
    CallDebugLog.instance.log('signal event: ${e.action}');
    switch (e.action) {
      case CallAction.accept:
        _pendingAccept = true;
        _maybeEnter();
        break;
      case CallAction.reject:
        _finish(_t('videoCallPeerRejected'));
        break;
      case CallAction.hangup:
        _finish(_t('videoCallEnded'));
        break;
      case CallAction.cancel:
        _finish(_t('videoCallPeerCancelled'));
        break;
    }
  }

  /// 拉引擎配置并创建媒体引擎（2026-11-13 通话浮窗需求：改由 CallService 持有）
  Future<void> _prepare() async {
    try {
      _engineReady = await CallService.instance.ensureMedia();
      final cfg = CallService.instance.config;
      CallDebugLog.instance.log(
          'config ready engine=${cfg?.engine} trtc=${cfg?.trtcUsable} webrtc=${cfg?.webrtcUsable} livekit=${cfg?.livekitUsable}');
      _prepared = true;
      _maybeEnter();
    } catch (e) {
      _prepared = true;
      CallDebugLog.instance.log('prepare EXCEPTION: $e');
      _setStatus(_t('videoCallStartFailed', {'error': '$e'}));
    }
  }

  /// 已接通（或已收到 accept）→ 进房；否则显示"等待对方接听…"
  void _maybeEnter() {
    final phase = CallService.instance.state.value?.phase;
    if (phase == CallPhase.connected || _pendingAccept) {
      _enterRoom();
    } else {
      _setStatus(_t('videoCallWaitingAnswer'));
      if (!_ringStarted) {
        _ringStarted = true;
        SoundService.instance.startRingback(); // 主叫回铃音（嘟嘟声）
      }
    }
  }

  /// 进房（引擎未配置时提示管理员配置）
  Future<void> _enterRoom() async {
    if (_enteredRoom || !mounted) return;
    if (!_prepared) return;
    if (!_engineReady) {
      debugPrint('[Call] 通话引擎未配置');
      setState(() => _status = _t('videoCallTrtcNotConfigured'));
      return;
    }
    _enteredRoom = true;
    try {
      // 权限拆分：麦克风是通话底线（拒绝才失败）；摄像头被拒/无设备时
      // 降级为「纯语音 + 仅接收对方画面 + 头像占位」，不再挂死整个通话
      final perms = await CallPermissions.ensureForVideoSplit();
      CallDebugLog.instance
          .log('permissions mic=${perms.mic} cam=${perms.cam}');
      if (!perms.mic) {
        _setStatus(_t('videoCallNeedPermissions'));
        return;
      }
      if (!perms.cam && mounted) {
        setState(() {
          _hasCamera = false;
          _cameraOff = true;
        });
        _setStatus(_t('videoCallCamFallback'));
      }
      // 2026-11-13 通话浮窗需求：已进房（如从浮窗恢复）不重复 join
      if (CallService.instance.mediaJoined) {
        setState(() {
          _connecting = false;
          _status = _t('videoCallInProgress');
        });
        return;
      }
      final err = await CallService.instance.joinMedia(
        roomId: widget.convId ?? '1',
        myId: CallService.instance.myId,
        isVideo: true,
        trtcSig: CallService.instance.config?.trtcSig,
      );
      if (err != null) {
        CallDebugLog.instance.log('media.join FAILED: $err');
        _setStatus(err);
        return;
      }
      CallDebugLog.instance.log('media.join OK → connected');
      setState(() {
        _connecting = false;
        _status = _t('videoCallInProgress');
      });
      SoundService.instance.stopRingback(); // 停止回铃音
      SoundService.instance.playCallConnected(); // 接通提示音
      // 媒体就绪 → 通知 CallService（被叫广播 join，触发主叫 offer）
      await CallService.instance.notifyMediaJoined();
    } catch (e) {
      CallDebugLog.instance.log('enterRoom flow EXCEPTION: $e');
      _setStatus(_t('videoCallEnterRoomFailed', {'error': '$e'}));
    }
  }

  /// 2026-11-01 排障：点状态文字 = 全量通话日志复制到剪贴板（发给开发定位）
  Future<void> _copyCallLogs() async {
    await CallDebugLog.instance.copy();
    if (!mounted) return;
    AppDialogs.toast(context, _t('callDebugCopied'));
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _connecting = true;
    });
  }

  /// 结束通话：提示 N 秒后自动退出
  void _finish(String msg) {
    if (!mounted) return;
    // 2026-11-13 通话浮窗需求：计时器已上移 CallService，页面不再持有
    SoundService.instance.stopRingback(); // 停止回铃音
    SoundService.instance.playHangup(); // 通话结束提示音
    setState(() {
      _status = msg;
      _connecting = true;
    });
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    CallService.instance.remotePeerId.removeListener(_onRemotePeerChanged);
    // 2026-11-13 通话浮窗需求：媒体引擎/信令 handler/计时归 CallService——
    // 页面 dispose（含缩小浮窗的 pop）绝不能 leave() 媒体；真正挂断由
    // CallService._reset 统一销毁。
    SoundService.instance.stopRingback(); // 兜底：离开页面确保回铃停止
    super.dispose();
  }

  /// 秒数 → mm:ss（数据源为 CallService.callSeconds，与浮窗一致）
  String _timeText(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 挂断：经 CallService 发 hangup/cancel 信令（含时长），会话里可见通话记录
  Future<void> _hangup() async {
    // 2026-11-13 通话浮窗需求：计时器已上移 CallService，页面不再持有
    SoundService.instance.stopRingback(); // 停止回铃音
    SoundService.instance.playHangup(); // 主动挂断提示音
    await CallService.instance.hangup();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _toggleMute() async {
    setState(() => _muted = !_muted);
    await CallService.instance.media?.setMuted(_muted);
  }

  Future<void> _toggleCamera() async {
    setState(() => _cameraOff = !_cameraOff);
    await CallService.instance.media?.setCameraOn(!_cameraOff);
  }

  Future<void> _switchCamera() async {
    setState(() => _flipCam = !_flipCam);
    await CallService.instance.media?.switchCamera();
  }

  /// 2026-11-13 通话浮窗需求：收起为应用内悬浮窗（媒体在 CallService，
  /// pop 路由不影响通话），供「缩小」按钮与返回手势共用
  void _minimize() {
    CallService.instance.minimize();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // 2026-11-13 通话浮窗需求：禁左滑/物理返回退出通话——返回手势改为收起浮窗
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _minimize();
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          // 顶部：最小化 + 安全 + 标题
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  // 2026-11-13 通话浮窗需求：左上角「缩小」按钮（收起为悬浮窗）
                  SizedBox(
                    width: 48,
                    child: IconButton(
                      tooltip: _t('callMinimize'),
                      onPressed: _minimize,
                      padding: EdgeInsets.zero,
                      icon: Icon(Icons.picture_in_picture_alt,
                          color: Colors.white.withValues(alpha: 0.75),
                          size: 22),
                    ),
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      const Icon(Icons.lock, color: Colors.white70, size: 14),
                      const SizedBox(width: 4),
                      Text(_t('videoCallEndToEndEncrypted'),
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12)),
                    ],
                  ),
                  const Spacer(),
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
          // 远端视频大画面（扩展占满剩余空间）
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ..._videoLayers(),
                // 顶部渐变遮罩（stops 限制在边缘 35%，避免整幅画面发灰）
                IgnorePointer(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black45, Colors.transparent],
                        stops: [0, 0.35],
                      ),
                    ),
                  ),
                ),
                // 底部渐变遮罩（按钮栏在视频区外，这里只留薄薄一层）
                IgnorePointer(
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black54, Colors.transparent],
                        stops: [0, 0.2],
                      ),
                    ),
                  ),
                ),
                // 中央：对方头像 + 姓名 + 通话时长（需求4：拨打界面显示对方昵称+头像）
                Align(
                  alignment: const Alignment(0, -0.55),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 2026-11-01 排障：点/长按对方头像 = 复制全量通话日志（成功弹 toast）
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _copyCallLogs,
                        onLongPress: _copyCallLogs,
                        child: _peerAvatarBadge(),
                      ),
                      const SizedBox(height: 10),
                      Text(widget.peerName,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w500)),
                      const SizedBox(height: 6),
                      // 2026-11-13 通话浮窗需求：通话时长改读 CallService.callSeconds
                      ValueListenableBuilder<int>(
                        valueListenable: CallService.instance.callSeconds,
                        builder: (context, sec, _) {
                          return Text(
                              _connecting
                                  ? _status
                                  : (sec == 0 ? _status : _timeText(sec)),
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 13));
                        },
                      ),
                    ],
                  ),
                ),
                // 小窗外框 + 点击互换（小窗永远在右上角，只换内容不换位置）
                if (_enteredRoom && _engineReady)
                  Positioned(
                    right: 16,
                    top: 16,
                    width: 110,
                    height: 150,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() => _swapped = !_swapped),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white24, width: 1),
                        ),
                        child: Align(
                          alignment: Alignment.bottomRight,
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.swap_horiz,
                                color: Colors.white70, size: 14),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 底部按钮栏（固定到底部，不会被推到顶部）
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
              child: _bottomBar(),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// 对方头像（无头像或加载失败回退首字母圆形）
  Widget _peerAvatarBadge() {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: AppTheme.primary,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: AppAvatar(
        url: widget.peerAvatar,
        name: widget.peerName,
        size: 64,
        background: AppTheme.primary,
      ),
    );
  }

  /// 视频双图层：本地/远端两个视图【常驻固定树位】，互换只改几何与层级，
  /// 绝不销毁重建渲染器 —— 重建会让远端流挂到第二路 sink 收不到帧，
  /// 小窗画面卡住（2026-09-17 两轮修复的最终形态）。
  /// 2026-11-13 通话浮窗需求：媒体引擎改从 CallService 取（服务层持有）。
  List<Widget> _videoLayers() {
    if (!_enteredRoom || !_engineReady) {
      return [_statusPlaceholder(_status)];
    }
    final media = CallService.instance.media;
    if (media == null) return [_statusPlaceholder(_status)];
    final localBig = _swapped;
    final localLayer = _videoLayer(media, big: localBig, remote: false);
    final remoteLayer = _videoLayer(media, big: !localBig, remote: true);
    // 列表末位绘制在上层：小窗永远盖在大窗上（layer key 保证各自 State 不互换）
    return localBig ? [localLayer, remoteLayer] : [remoteLayer, localLayer];
  }

  Widget _videoLayer(CallMedia media, {required bool big, required bool remote}) {
    Widget content;
    if (remote) {
      if (_remoteUserId != null) {
        content = media.remoteVideo(_remoteUserId!);
      } else {
        content = big
            ? IgnorePointer(
                child: _statusPlaceholder(_t('videoCallWaitingAnswer')))
            : _pipPlaceholder(Icons.person_outline);
      }
    } else {
      if (_cameraOff || !_hasCamera) {
        content = big
            ? _statusPlaceholder(_t('videoCallCameraOffLabel'),
                icon: Icons.videocam_off)
            : _pipAvatar();
      } else {
        content = media.localVideo();
      }
    }
    final key =
        remote ? const ValueKey('layer-remote') : const ValueKey('layer-local');
    final clip = ClipRRect(
      // 大窗也保留 ClipRRect（radius 0）：互换时子树形状不变，渲染器不重建
      borderRadius: BorderRadius.circular(big ? 0 : 10),
      child: content,
    );
    if (big) {
      return Positioned.fill(key: key, child: clip);
    }
    return Positioned(
      key: key,
      right: 16,
      top: 16,
      width: 110,
      height: 150,
      child: clip,
    );
  }

  Widget _statusPlaceholder(String text, {IconData? icon}) {
    return Container(
      color: const Color(0xFF1A1A1A),
      alignment: Alignment.center,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon ?? (_cameraOff ? Icons.videocam_off : Icons.videocam),
              color: Colors.white24, size: 64),
          const SizedBox(height: 12),
          Text(text,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
        ],
      ),
    );
  }

  Widget _pipPlaceholder(IconData icon, {String? label}) {
    return Container(
      width: 110,
      height: 150,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: Colors.white24, size: 36),
          if (label != null) ...[
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        ],
      ),
    );
  }

  /// 无摄像头/已关摄像头时的小窗占位：自己头像（AppAvatar，取不到回退首字）
  Widget _pipAvatar() {
    return Container(
      width: 110,
      height: 150,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 1),
      ),
      alignment: Alignment.center,
      child: AppAvatar(
        url: UserCache.myAvatar ?? '',
        name: UserCache.myProfileData?['nickname']?.toString() ?? '我',
        size: 52,
        background: AppTheme.primary,
      ),
    );
  }

  Widget _bottomBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ctrlBtn(
            _muted ? Icons.mic_off : Icons.mic,
            _muted ? _t('videoCallMuted') : _t('videoCallMicrophone'),
            _toggleMute,
            active: _muted),
        _ctrlBtn(Icons.call_end, _t('videoCallHangUp'), _hangup, danger: true),
        // 无摄像头（权限被拒/无设备）时不显示摄像头开关与翻转——点了也没用
        if (_hasCamera) ...[
          _ctrlBtn(
              _cameraOff ? Icons.videocam_off : Icons.videocam,
              _cameraOff ? _t('videoCallCameraClosed') : _t('videoCallCamera'),
              _toggleCamera,
              active: _cameraOff),
          _ctrlBtn(Icons.cameraswitch, _t('videoCallFlip'), _switchCamera,
              active: _flipCam),
        ],
      ],
    );
  }

  Widget _ctrlBtn(IconData icon, String label, VoidCallback onTap,
      {bool active = false, bool danger = false}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkResponse(
          onTap: onTap,
          radius: 36,
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: danger
                  ? AppTheme.danger
                  : (active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.2)),
            ),
            child: Icon(icon,
                color: active && !danger ? Colors.black : Colors.white,
                size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 12)),
      ],
    );
  }
}
