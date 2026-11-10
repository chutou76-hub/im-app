import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../utils/call_permissions.dart';
import '../widgets/app_avatar.dart';

/// 群组通话页（语音头像宫格 / 视频视频宫格）。
///
/// - 参与人来自 CallService.participants（join/leave/sdp 驱动实时增减）；
/// - 媒体引擎按后台 call_engine 选择（TRTC 房间原生多人 / WebRTC Mesh）；
/// - 入口：主叫 chat_page 发 startGroupCall 后进入；被叫 incoming_call_page
///   accept 后进入（此时已 connected，直接进房）。
class GroupCallPage extends StatefulWidget {
  const GroupCallPage({super.key});

  @override
  State<GroupCallPage> createState() => _GroupCallPageState();
}

class _GroupCallPageState extends State<GroupCallPage> {
  bool _muted = false;
  bool _cameraOff = false;
  bool _hasCamera = true; // 本端是否有可用摄像头（权限被拒 → 宫格头像占位降级）
  bool _flipCam = false;
  bool _connecting = true;
  String _status = '';
  StreamSubscription<CallEvent>? _sub;
  // 2026-11-13 通话浮窗需求：媒体引擎与通话计时上移 CallService——
  // 页面不再自建 CallMedia / 计时器，收起为浮窗（pop 路由）不再挂断媒体。

  bool _enteredRoom = false;
  bool _engineReady = false;
  bool _prepared = false;
  bool _ringStarted = false; // 主叫回铃音是否已启动

  String _t(String key, [Map<String, String>? params]) =>
      mounted ? AppLocalizations.of(context).t(key, params) : key;

  String get _myId => CallService.instance.myId;

  bool get _isVideo => CallService.instance.state.value?.callType == 'video';

  String? get _roomTitle => CallService.instance.state.value?.peerName;

  @override
  void initState() {
    super.initState();
    _status = _t('groupCallWaiting');
    _sub = CallService.instance.events.listen(_onCallEvent);
    _prepare();
  }

  void _onCallEvent(CallEvent e) {
    final s = CallService.instance.state.value;
    if (s == null || e.convId != s.convId) return;
    switch (e.action) {
      case CallAction.accept:
        // 群通话：首个成员接听即进房（自己接听时 accept 已在 accept() 处理）
        _enterRoom();
        break;
      case CallAction.hangup:
      case CallAction.cancel:
        _finish(_t('groupCallEnded'));
        break;
    }
  }

  Future<void> _prepare() async {
    try {
      // 2026-11-13 通话浮窗需求：媒体引擎改由 CallService 创建/持有
      _engineReady = await CallService.instance.ensureMedia();
      _prepared = true;
      // 被叫：accept() 已把状态置 connected → 直接进房
      final phase = CallService.instance.state.value?.phase;
      if (phase == CallPhase.connected) {
        _enterRoom();
      } else if (mounted) {
        setState(() => _status = _t('groupCallWaiting'));
        if (!_ringStarted) {
          _ringStarted = true;
          SoundService.instance.startRingback(); // 主叫回铃音（嘟嘟声）
        }
      }
    } catch (e) {
      _prepared = true;
      _setStatus(_t('videoCallStartFailed', {'error': '$e'}));
    }
  }

  Future<void> _enterRoom() async {
    if (_enteredRoom || !mounted) return;
    if (!_prepared) return;
    if (!_engineReady) {
      debugPrint('[GroupCall] 通话引擎未配置');
      setState(() => _status = _t('videoCallTrtcNotConfigured'));
      return;
    }
    _enteredRoom = true;
    try {
      if (_isVideo) {
        // 权限拆分：麦克风是底线（拒绝才失败）；摄像头被拒降级为纯语音 +
        // 仅接收对方画面（宫格显示头像占位），不再挂死通话
        final perms = await CallPermissions.ensureForVideoSplit();
        if (!perms.mic) {
          _setStatus(_t('videoCallNeedPermissions'));
          return;
        }
        _hasCamera = perms.cam;
      } else {
        final granted = await CallPermissions.ensureForVoice();
        if (!granted) {
          _setStatus(_t('voiceCallNeedMicPermission'));
          return;
        }
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
        roomId: CallService.instance.state.value?.convId ?? '1',
        myId: _myId,
        isVideo: _isVideo,
        trtcSig: CallService.instance.config?.trtcSig,
      );
      if (err != null) {
        _setStatus(err);
        return;
      }
      setState(() {
        _connecting = false;
        _status = _t('videoCallInProgress');
      });
      SoundService.instance.stopRingback(); // 停止回铃音
      SoundService.instance.playCallConnected(); // 接通提示音
      // 媒体就绪 → 广播 join（房内已有成员向自己 offer）
      await CallService.instance.notifyMediaJoined();
    } catch (e) {
      _setStatus(_t('videoCallEnterRoomFailed', {'error': '$e'}));
    }
  }

  void _setStatus(String s) {
    if (!mounted) return;
    setState(() {
      _status = s;
      _connecting = true;
    });
  }

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
    final isVideo = _isVideo;
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
          // 顶部：群名 + 通话状态/时长（右上角叠「缩小」按钮）
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              // 2026-11-13 通话浮窗需求：右上角「缩小」按钮（收起为悬浮窗）
              child: SizedBox(
                width: double.infinity,
                child: Stack(
                  children: [
                    Column(
                      children: [
                        Text(_roomTitle ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
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
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        tooltip: _t('callMinimize'),
                        onPressed: _minimize,
                        icon: Icon(Icons.picture_in_picture_alt,
                            color: Colors.white.withValues(alpha: 0.75),
                            size: 22),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 参与人宫格
          Expanded(
            child: ValueListenableBuilder<List<CallParticipant>>(
              valueListenable: CallService.instance.participants,
              builder: (context, members, _) {
                if (members.isEmpty) {
                  return _statusPlaceholder(_status);
                }
                final cross =
                    members.length <= 1 ? 1 : (members.length <= 4 ? 2 : 3);
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: GridView.count(
                    crossAxisCount: cross,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: isVideo ? 0.78 : 1.0,
                    children: [
                      for (final p in members)
                        isVideo
                            ? _videoCell(p)
                            : _voiceCell(p, count: members.length),
                    ],
                  ),
                );
              },
            ),
          ),
          // 底部按钮栏
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 20),
              child: _bottomBar(isVideo),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ============================ 宫格单元 ============================

  /// 视频单元：自己=本地预览，其他成员=远端画面（未出画面时占位）
  /// 2026-11-13 通话浮窗需求：媒体引擎改从 CallService 取（服务层持有）
  Widget _videoCell(CallParticipant p) {
    final isMe = p.id == _myId;
    final media = CallService.instance.media;
    Widget content;
    if (isMe && (_cameraOff || !_hasCamera)) {
      content = _cellAvatar(p, size: 56);
    } else if (!_enteredRoom || !_engineReady || media == null) {
      content = _cellAvatar(p, size: 56);
    } else if (isMe) {
      content = media.localVideo();
    } else {
      content = media.remoteVideo(p.id);
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(20),
              ),
              constraints: const BoxConstraints(maxWidth: 140),
              child: Text(
                isMe ? _t('groupCallMe') : (p.name.isEmpty ? p.id : p.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 语音单元：大头像圆 + 昵称
  Widget _voiceCell(CallParticipant p, {required int count}) {
    final isMe = p.id == _myId;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _cellAvatar(p, size: count <= 2 ? 88 : 64),
          const SizedBox(height: 10),
          Text(
            isMe ? _t('groupCallMe') : (p.name.isEmpty ? p.id : p.name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 成员头像（无图回退首字母圆）
  Widget _cellAvatar(CallParticipant p, {double size = 56}) {
    final name = p.name.isEmpty ? p.id : p.name;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppTheme.primary,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: AppAvatar(
        url: p.avatar,
        name: name,
        size: size,
        background: AppTheme.primary,
      ),
    );
  }

  Widget _statusPlaceholder(String text) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(_isVideo ? Icons.videocam : Icons.call,
              color: Colors.white24, size: 56),
          const SizedBox(height: 12),
          Text(text,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5), fontSize: 14)),
        ],
      ),
    );
  }

  // ============================ 底部按钮 ============================

  Widget _bottomBar(bool isVideo) {
    final children = <Widget>[
      _ctrlBtn(
          _muted ? Icons.mic_off : Icons.mic,
          _muted ? _t('videoCallMuted') : _t('videoCallMicrophone'),
          _toggleMute,
          active: _muted),
      _ctrlBtn(Icons.call_end, _t('videoCallHangUp'), _hangup, danger: true),
    ];
    // 无摄像头（权限被拒）时不显示摄像头开关与翻转——点了也没用
    if (isVideo && _hasCamera) {
      children.addAll([
        _ctrlBtn(
            _cameraOff ? Icons.videocam_off : Icons.videocam,
            _cameraOff ? _t('videoCallCameraClosed') : _t('videoCallCamera'),
            _toggleCamera,
            active: _cameraOff),
        _ctrlBtn(Icons.cameraswitch, _t('videoCallFlip'), _switchCamera,
            active: _flipCam),
      ]);
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
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
