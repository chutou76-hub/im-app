import 'package:flutter/material.dart';

import '../app_navigator.dart';
import '../l10n/app_locale.dart';
import '../pages/group_call_page.dart';
import '../pages/video_call_page.dart';
import '../pages/voice_call_page.dart';
import '../services/call_service.dart';
import '../services/sound_service.dart';
import '../theme/app_theme.dart';
import 'app_avatar.dart';

/// 2026-11-13 通话浮窗需求：应用内通话悬浮小窗。
///
/// - 挂在 MaterialApp.builder 层（CallOverlay 的 Stack 内，与来电浮层同层）；
/// - 仅在「通话进行中（state != null）且已收起（minimized = true）」时显示；
///   全屏通话页打开 / 通话结束（state 变 null）/ 来电浮层弹出时自动隐藏；
/// - 可拖动（拖不出屏幕边界，不做边缘吸附）；
/// - 单聊视频显示远端画面缩略；语音/群通话显示头像；均带通话时长；
/// - 点击窗体恢复全屏通话页（按 CallState.callType/isGroup 选择页面）；
/// - 窗体右上角红色挂断按钮直接结束通话（CallService.hangup）。
class CallFloatWindow extends StatefulWidget {
  const CallFloatWindow({super.key});

  @override
  State<CallFloatWindow> createState() => _CallFloatWindowState();
}

class _CallFloatWindowState extends State<CallFloatWindow> {
  /// 视频浮窗尺寸（远端画面缩略，比例贴近通话页 PIP 小窗）
  static const Size _videoSize = Size(128, 176);

  /// 语音/群通话浮窗尺寸（横向胶囊卡片）
  static const Size _pillSize = Size(196, 64);

  /// 窗体与屏幕边缘的最小间距
  static const double _margin = 12;

  Offset _pos = Offset.zero;
  bool _posInitialized = false;

  /// 2026-11-13 通话浮窗需求（QA 回归修复）：跨通话复位——记录当前浮窗
  /// 对应的会话 ID，换了一通电话（convId 变化）就回到默认停靠位置
  String? _lastConvId;

  /// 取本地化文案
  String _t(String key, [Map<String, String>? params]) =>
      AppLocalizations.of(context).t(key, params);

  /// 点击浮窗 → 恢复全屏通话页（按通话类型选择页面）。
  /// minimized 已为 false（已在全屏通话页）时不重复 push。
  void _restore(CallState s) {
    if (!CallService.instance.minimized.value) return;
    CallService.instance.minimized.value = false;
    final Widget page;
    if (s.isGroup) {
      page = const GroupCallPage();
    } else if (s.callType == 'video') {
      page = VideoCallPage(
        peerName: s.peerName,
        peerAvatar: s.peerAvatar,
        convId: s.convId,
      );
    } else {
      page = VoiceCallPage(
        peerName: s.peerName,
        peerAvatar: s.peerAvatar,
        convId: s.convId,
      );
    }
    appNavigatorKey.currentState
        ?.push(MaterialPageRoute(builder: (_) => page));
  }

  /// 拖动：跟随手指，松手不吸附，但钳制在屏幕范围内
  ///（窗口比屏幕还大的极端情况下钳到边缘，避免 RangeError）
  void _onPanUpdate(DragUpdateDetails d, Size win, Size screen) {
    final maxX = _margin > screen.width - win.width - _margin
        ? _margin
        : screen.width - win.width - _margin;
    final maxY = _margin > screen.height - win.height - _margin
        ? _margin
        : screen.height - win.height - _margin;
    setState(() {
      final dx = (_pos.dx + d.delta.dx).clamp(_margin, maxX);
      final dy = (_pos.dy + d.delta.dy).clamp(_margin, maxY);
      _pos = Offset(dx, dy);
    });
  }

  /// 快捷挂断：与全屏通话页一致——先停回铃 + 播挂断提示音（QA 回归修复：
  /// 此前浮窗挂断无声，与全屏页体验不一致），再结束通话（state 变 null
  /// 后浮窗自动隐藏）
  Future<void> _hangup() async {
    SoundService.instance.stopRingback();
    SoundService.instance.playHangup();
    await CallService.instance.hangup();
  }

  @override
  Widget build(BuildContext context) {
    final service = CallService.instance;
    return ValueListenableBuilder<CallState?>(
      valueListenable: service.state,
      builder: (context, s, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: service.minimized,
          builder: (context, minimized, _) {
            // 仅「通话进行中且已收起」显示；来电浮层（incoming）优先级更高
            if (s == null ||
                !minimized ||
                s.phase == CallPhase.incoming) {
              return const SizedBox.shrink();
            }
            final screen = MediaQuery.of(context).size;
            // 单聊视频 → 远端画面浮窗；语音/群通话 → 胶囊浮窗
            final isVideo = s.callType == 'video' && !s.isGroup;
            final win = isVideo ? _videoSize : _pillSize;
            // 2026-11-13 通话浮窗需求（QA 回归修复）：跨通话复位——换了
            // 一通电话（convId 变化）回到默认停靠位置；同一通电话保持
            // 用户拖动过的位置（保持克制，不做边缘吸附）
            if (_lastConvId != s.convId) {
              _lastConvId = s.convId;
              _posInitialized = false;
            }
            // 首次显示：默认停靠屏幕右上区域
            if (!_posInitialized) {
              _posInitialized = true;
              _pos = Offset(
                (screen.width - win.width - _margin)
                    .clamp(0.0, (screen.width - win.width).clamp(0.0, double.infinity)),
                96,
              );
            }
            // 2026-11-13 通话浮窗需求（QA 回归修复）：每次可见都钳回屏内
            // ——屏幕旋转/分屏尺寸变化后位置自愈（不触发重建循环）
            final maxX = _margin > screen.width - win.width - _margin
                ? _margin
                : screen.width - win.width - _margin;
            final maxY = _margin > screen.height - win.height - _margin
                ? _margin
                : screen.height - win.height - _margin;
            _pos = Offset(
              _pos.dx.clamp(_margin, maxX),
              _pos.dy.clamp(_margin, maxY),
            );
            return Positioned(
              left: _pos.dx,
              top: _pos.dy,
              width: win.width,
              height: win.height,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => _onPanUpdate(d, win, screen),
                onTap: () => _restore(s),
                child: Container(
                  decoration: BoxDecoration(
                    // 半透明深底 + 圆角卡片 + 阴影（与通话页 PIP 小窗观感一致）
                    color: const Color(0xE6141414),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white24, width: 1),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: isVideo
                      ? _videoBody(s)
                      : _pillBody(s),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ============================ 浮窗内容 ============================

  /// 单聊视频浮窗：远端画面缩略（未就绪回退对方头像）+ 底部时长条 + 挂断按钮
  Widget _videoBody(CallState s) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ValueListenableBuilder<String?>(
          valueListenable: CallService.instance.remotePeerId,
          builder: (context, uid, _) {
            final media = CallService.instance.media;
            final Widget face;
            if (uid != null && uid.isNotEmpty && media != null) {
              // 远端流缩略（媒体引擎在服务层持有，pop 路由不影响画面）
              face = media.remoteVideo(uid);
            } else {
              face = Center(
                child: AppAvatar(
                  url: s.peerAvatar,
                  name: s.peerName,
                  size: 56,
                  background: AppTheme.primary,
                ),
              );
            }
            return face;
          },
        ),
        // 底部半透明信息条：对方昵称 + 时长
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: Colors.black.withValues(alpha: 0.55),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    s.peerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11),
                  ),
                ),
                _timeLabel(compact: true),
              ],
            ),
          ),
        ),
        // 挂断快捷按钮
        Positioned(
          right: 4,
          top: 4,
          child: _hangupButton(),
        ),
      ],
    );
  }

  /// 语音/群通话浮窗：头像 + 昵称 + 时长（横向胶囊）+ 挂断按钮
  Widget _pillBody(CallState s) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      child: Row(
        children: [
          AppAvatar(
            url: s.peerAvatar,
            name: s.peerName,
            size: 44,
            background: AppTheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                _timeLabel(compact: false),
              ],
            ),
          ),
          _hangupButton(),
        ],
      ),
    );
  }

  /// 时长标签（接通后 mm:ss；未接通显示等待文案）
  Widget _timeLabel({required bool compact}) {
    final s = CallService.instance.state.value;
    final connected = s?.phase == CallPhase.connected;
    return ValueListenableBuilder<int>(
      valueListenable: CallService.instance.callSeconds,
      builder: (context, sec, _) {
        final text = connected
            ? _formatSeconds(sec)
            : _t('callFloatWaiting');
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: compact ? 10 : 11,
          ),
        );
      },
    );
  }

  /// 红色挂断快捷按钮（点按直接结束通话，浮窗随 state 置空自动隐藏）
  Widget _hangupButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _hangup,
      child: Container(
        width: 28,
        height: 28,
        // const 化（analyzer 建议；AppTheme.danger 为编译期常量）
        decoration: const BoxDecoration(
          color: AppTheme.danger,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.call_end, color: Colors.white, size: 16),
      ),
    );
  }

  /// 秒数 → mm:ss
  String _formatSeconds(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
