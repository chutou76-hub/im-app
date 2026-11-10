import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_locale.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import '../utils/call_debug_log.dart';
import '../utils/call_permissions.dart';
import '../widgets/app_avatar.dart';
import '../widgets/app_dialogs.dart';

/// 语音通话页（单聊）：模糊背景 + 大头像 + 对方姓名 + 通话时长 + 底部按钮栏。
/// 媒体引擎按后台 call_engine 选择（TRTC / WebRTC），页面不感知差异。
class VoiceCallPage extends StatefulWidget {
  final String peerName;
  final String peerAvatar;
  final String? convId; // 会话 ID（房间号）
  const VoiceCallPage(
      {super.key, required this.peerName, this.peerAvatar = '', this.convId});

  @override
  State<VoiceCallPage> createState() => _VoiceCallPageState();
}

class _VoiceCallPageState extends State<VoiceCallPage> {
  bool _muted = false;
  bool _speaker = true;
  bool _connecting = true;
  String _status = '正在连接…';
  StreamSubscription<CallEvent>? _sub;
  // 2026-11-13 通话浮窗需求：媒体引擎与通话计时上移 CallService——
  // 页面不再自建 CallMedia / 计时器，收起为浮窗（pop 路由）不再挂断媒体。

  bool _enteredRoom = false;
  bool _engineReady = false;
  bool _prepared = false;
  bool _pendingAccept = false;
  bool _ringStarted = false; // 主叫回铃音是否已启动

  /// 取本地化文案（未挂载时回退为 key，避免访问失效 context）
  String _t(String key, [Map<String, String>? params]) =>
      mounted ? AppLocalizations.of(context).t(key, params) : key;

  @override
  void initState() {
    super.initState();
    // 2026-11-01 排障：通话页点状态文字可复制全量日志（CallDebugLog）
    CallDebugLog.instance.clear();
    CallDebugLog.instance.log(
        'VoiceCallPage open conv=${widget.convId} myId=${CallService.instance.myId} hasSig=${CallService.instance.config?.trtcSig.isNotEmpty == true}');
    _sub = CallService.instance.events.listen(_onCallEvent);
    _prepare();
  }

  void _onCallEvent(CallEvent e) {
    if (e.convId != widget.convId) return;
    CallDebugLog.instance.log('signal event: ${e.action}');
    switch (e.action) {
      case CallAction.accept:
        _pendingAccept = true;
        _maybeEnter();
        break;
      case CallAction.reject:
        _finish(_t('voiceCallPeerRejected'));
        break;
      case CallAction.hangup:
        _finish(_t('voiceCallEnded'));
        break;
      case CallAction.cancel:
        _finish(_t('voiceCallPeerCancelled'));
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
      _setStatus(_t('voiceCallStartFailed', {'error': '$e'}));
    }
  }

  void _maybeEnter() {
    final phase = CallService.instance.state.value?.phase;
    if (phase == CallPhase.connected || _pendingAccept) {
      _enterRoom();
    } else {
      _setStatus(_t('voiceCallWaitingAnswer'));
      if (!_ringStarted) {
        _ringStarted = true;
        SoundService.instance.startRingback(); // 主叫回铃音（嘟嘟声）
      }
    }
  }

  Future<void> _enterRoom() async {
    if (_enteredRoom || !mounted) return;
    if (!_prepared) return;
    if (!_engineReady) {
      setState(() => _status = _t('voiceCallUserSigFailed'));
      return;
    }
    _enteredRoom = true;
    try {
      final granted = await CallPermissions.ensureForVoice();
      CallDebugLog.instance.log('permissions mic=$granted');
      if (!granted) {
        _setStatus(_t('voiceCallNeedPermissions'));
        return;
      }
      // 2026-11-13 通话浮窗需求：已进房（如从浮窗恢复）不重复 join
      if (CallService.instance.mediaJoined) {
        setState(() {
          _connecting = false;
          _status = _t('voiceCallInProgress');
        });
        return;
      }
      final err = await CallService.instance.joinMedia(
        roomId: widget.convId ?? '1',
        myId: CallService.instance.myId,
        isVideo: false,
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
        _status = _t('voiceCallInProgress');
      });
      SoundService.instance.stopRingback(); // 停止回铃音
      SoundService.instance.playCallConnected(); // 接通提示音
      await CallService.instance.notifyMediaJoined();
    } catch (e) {
      CallDebugLog.instance.log('enterRoom flow EXCEPTION: $e');
      _setStatus(_t('voiceCallEnterRoomFailed', {'error': '$e'}));
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

  Future<void> _toggleSpeaker() async {
    setState(() => _speaker = !_speaker);
    // 2026-11-10 扬声器修复：setSpeaker 已提升进 CallMedia 接口，三引擎
    // （TRTC / WebRTC / LiveKit）统一实现——此前 LiveKit 引擎无对应分支，
    // 按钮点击只翻 UI 状态不出声；Web 平台由实现内部跳过。
    await CallService.instance.media?.setSpeaker(_speaker);
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
      body: Container(
        width: double.infinity,
        height: double.infinity,
        color: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              // 2026-11-13 通话浮窗需求：右上角「缩小」按钮（收起为悬浮窗）
              Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  tooltip: _t('callMinimize'),
                  onPressed: _minimize,
                  icon: Icon(Icons.picture_in_picture_alt,
                      color: Colors.white.withValues(alpha: 0.75), size: 22),
                ),
              ),
              const Spacer(flex: 2),
              // 2026-11-01 排障：点/长按对方头像 = 复制全量通话日志（成功弹 toast）
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copyCallLogs,
                onLongPress: _copyCallLogs,
                child: _avatar(),
              ),
              const SizedBox(height: 24),
              Text(widget.peerName,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              // 2026-11-13 通话浮窗需求：通话时长改读 CallService.callSeconds
              ValueListenableBuilder<int>(
                valueListenable: CallService.instance.callSeconds,
                builder: (context, sec, _) {
                  return Text(
                      _connecting
                          ? _status
                          : (sec == 0 ? _status : _timeText(sec)),
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.65),
                          fontSize: 14));
                },
              ),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(40, 0, 40, 56),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _actionBtn(
                      icon: _muted ? Icons.mic_off : Icons.mic,
                      label: _muted
                          ? _t('voiceCallMuted')
                          : _t('voiceCallMicrophone'),
                      color: Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleMute,
                    ),
                    _actionBtn(
                      icon: Icons.call_end,
                      label: _t('voiceCallHangUp'),
                      color: AppTheme.danger,
                      iconColor: Colors.white,
                      onTap: _hangup,
                    ),
                    _actionBtn(
                      icon: _speaker ? Icons.volume_up : Icons.hearing,
                      label: _speaker
                          ? _t('voiceCallSpeaker')
                          : _t('voiceCallEarpiece'),
                      color: Colors.white.withValues(alpha: 0.2),
                      iconColor: Colors.white,
                      onTap: _toggleSpeaker,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _avatar() {
    return Container(
      width: 128,
      height: 128,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.primary,
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.45),
            blurRadius: 32,
            spreadRadius: 6,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: AppAvatar(
        url: widget.peerAvatar,
        name: widget.peerName,
        size: 128,
        background: AppTheme.primary,
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkResponse(
          onTap: onTap,
          radius: 44,
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 30),
          ),
        ),
        const SizedBox(height: 10),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 13)),
      ],
    );
  }
}
