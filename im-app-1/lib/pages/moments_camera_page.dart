import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_locale.dart';

/// 微信式朋友圈拍摄页（2026-11-07 需求3，camera 包 0.11.0）：
/// - 全屏取景，左上角 X 关闭；
/// - 最下方黑色横条：左=闪光灯开关、中=大圆按钮（短按拍照 / 长按录视频，最长 60s）、
///   右=前后摄像头切换；
/// - 拍完进入预览确认页（右下角 确认/重拍），确认后带结果返回发布流程。
/// 返回 [CameraCaptureResult]（null=取消），由发布入口按 isVideo 分流。
class CameraCaptureResult {
  final XFile file;
  final bool isVideo;
  const CameraCaptureResult({required this.file, required this.isVideo});
}

class MomentsCameraPage extends StatefulWidget {
  const MomentsCameraPage({super.key});

  @override
  State<MomentsCameraPage> createState() => _MomentsCameraPageState();
}

class _MomentsCameraPageState extends State<MomentsCameraPage>
    with WidgetsBindingObserver {
  /// 录像最长时长（秒），到点自动停止进入预览
  static const int _maxRecordSecs = 60;

  List<CameraDescription> _cams = const [];
  CameraController? _ctrl;
  bool _initializing = true;
  bool _flashOn = false;

  /// 相机初始化失败（权限被拒/相机被占用等）：界面显示失败占位 + 重试
  bool _failed = false;

  bool _recording = false;
  int _recSecs = 0;
  Timer? _recTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setup();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recTimer?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  // 切后台时释放相机（系统会收回），回前台重建
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) {
      _recTimer?.cancel();
      _recording = false;
      _ctrl?.dispose();
      _ctrl = null;
    } else if (state == AppLifecycleState.resumed && _ctrl == null) {
      _setup();
    }
  }

  /// 初始化相机（首次用后置优先；切换摄像头时传指定描述）。
  /// 意图+2026-11-07（夜5）：首次进入「初始化失败、重试才好」——根因是首次
  /// 未授权时直接 initialize，权限弹窗期间初始化抛 CameraAccessDenied。
  /// 现在初始化前先请求相机+麦克风权限，未授权不建控制器（失败占位可重试）。
  Future<void> _setup({CameraDescription? desc}) async {
    setState(() {
      _initializing = true;
      _failed = false;
    });
    try {
      // 权限先行：未授权会触发系统弹窗，等待用户选择；拒绝则走失败占位
      final ps = await [Permission.camera, Permission.microphone].request();
      if (!(ps[Permission.camera]?.isGranted ?? false) ||
          !(ps[Permission.microphone]?.isGranted ?? false)) {
        _failed = true;
        if (mounted) setState(() => _initializing = false);
        return;
      }
      if (_cams.isEmpty) {
        _cams = await availableCameras();
      }
      desc ??= _cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cams.first,
      );
      final old = _ctrl;
      final c = CameraController(desc, ResolutionPreset.high,
          enableAudio: true, imageFormatGroup: ImageFormatGroup.jpeg);
      _ctrl = c;
      // 旧的先释放（不阻塞新初始化）
      unawaited(old?.dispose());
      await c.initialize();
      if (_flashOn) {
        await c.setFlashMode(FlashMode.torch);
      } else {
        await c.setFlashMode(FlashMode.off);
      }
    } catch (_) {
      // 初始化失败（权限/占用）：保持界面失败占位，可点重试
      try {
        await _ctrl?.dispose();
      } catch (_) {}
      _ctrl = null;
      _failed = true;
    }
    if (mounted) setState(() => _initializing = false);
  }

  void _switchCamera() {
    if (_cams.length < 2 || _recording || _initializing) return;
    final cur = _ctrl?.description;
    final next = _cams.firstWhere((c) => c != cur, orElse: () => _cams.first);
    _setup(desc: next);
  }

  Future<void> _toggleFlash() async {
    setState(() => _flashOn = !_flashOn);
    try {
      await _ctrl?.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
  }

  Future<void> _takePhoto() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _recording) return;
    try {
      final file = await ctrl.takePicture();
      await _toPreview(file, false);
    } catch (_) {}
  }

  Future<void> _startRecord() async {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _recording) return;
    try {
      await ctrl.prepareForVideoRecording();
      await ctrl.startVideoRecording();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _recSecs = 0;
      });
      _recTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        setState(() => _recSecs = t.tick);
        if (t.tick >= _maxRecordSecs) _stopRecord();
      });
    } catch (_) {}
  }

  Future<void> _stopRecord() async {
    final ctrl = _ctrl;
    _recTimer?.cancel();
    if (ctrl == null || !_recording) return;
    setState(() => _recording = false);
    try {
      final file = await ctrl.stopVideoRecording();
      await _toPreview(file, true);
    } catch (_) {}
  }

  /// 进入预览确认页；确认（返回结果）→ 原样带回上一页；重拍/关闭 → 留在拍摄页
  Future<void> _toPreview(XFile file, bool isVideo) async {
    final result = await Navigator.push<CameraCaptureResult>(
      context,
      MaterialPageRoute(
        builder: (_) => MomentsCameraPreviewPage(file: file, isVideo: isVideo),
      ),
    );
    if (result != null && mounted) {
      Navigator.pop(context, result);
    }
  }

  String get _recText {
    final m = (_recSecs ~/ 60).toString().padLeft(2, '0');
    final s = (_recSecs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          // 左上角 X 关闭
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 26, color: Colors.white),
              ),
            ),
          ),
          // 录制中：顶部计时 + 红点
          if (_recording)
            SafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            color: Color(0xFFE9564E), shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 6),
                      Text(_recText,
                          style: const TextStyle(
                              fontSize: 14,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          // 底部黑色横条操作区
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              color: Colors.black,
              padding: EdgeInsets.only(
                  top: 10,
                  bottom: MediaQuery.of(context).padding.bottom + 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 提示语（空闲时显示）
                  SizedBox(
                    height: 20,
                    child: !_recording
                        ? Text(t('momentsCameraHint'),
                            style: const TextStyle(
                                fontSize: 12, color: Colors.white60))
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // 左：闪光灯开关
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: IconButton(
                          onPressed: _initializing ? null : _toggleFlash,
                          icon: Icon(
                            _flashOn
                                ? Icons.flash_on
                                : Icons.flash_off_outlined,
                            size: 26,
                            color: _flashOn ? Colors.amber : Colors.white,
                          ),
                        ),
                      ),
                      // 中：快门大圆按钮（短按拍照 / 长按录像）
                      _shutterButton(),
                      // 右：前后摄像头切换
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: IconButton(
                          onPressed: _switchCamera,
                          icon: const Icon(Icons.cameraswitch_outlined,
                              size: 26, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // 初始化中占位 / 失败占位 + 重试
          if (_initializing)
            const Center(
                child: CircularProgressIndicator(color: Colors.white70))
          else if (_failed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.no_photography_outlined,
                      size: 44, color: Colors.white38),
                  const SizedBox(height: 12),
                  Text(t('momentsCameraFailed'),
                      style:
                          const TextStyle(fontSize: 14, color: Colors.white54)),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _setup,
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white),
                    child: Text(t('momentsCameraRetake')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 全屏取景：把预览等比放大到铺满屏幕（camera 官方示例同款 transform）
  Widget _preview() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) {
      return Container(color: Colors.black);
    }
    final size = MediaQuery.of(context).size;
    final scale = 1 / (ctrl.value.aspectRatio * size.aspectRatio);
    return ClipRect(
      child: Transform.scale(
        scale: scale,
        alignment: Alignment.center,
        child: Center(child: CameraPreview(ctrl)),
      ),
    );
  }

  /// 快门按钮：外圈白环 + 内芯（拍照白 / 录像红缩）
  Widget _shutterButton() {
    return GestureDetector(
      onTap: _takePhoto,
      onLongPressStart: (_) => _startRecord(),
      onLongPressEnd: (_) => _stopRecord(),
      onLongPressCancel: _stopRecord,
      child: Container(
        width: 78,
        height: 78,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
              color: _recording ? const Color(0xFFE9564E) : Colors.white,
              width: 4),
        ),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: _recording ? 40 : 62,
          height: _recording ? 40 : 62,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _recording ? const Color(0xFFE9564E) : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 拍摄预览确认页：照片/视频回看，右下角 重拍 / 确认。
/// pop(CameraCaptureResult) = 确认；pop(null) = 重拍或关闭。
class MomentsCameraPreviewPage extends StatefulWidget {
  final XFile file;
  final bool isVideo;
  const MomentsCameraPreviewPage(
      {super.key, required this.file, required this.isVideo});

  @override
  State<MomentsCameraPreviewPage> createState() =>
      _MomentsCameraPreviewPageState();
}

class _MomentsCameraPreviewPageState extends State<MomentsCameraPreviewPage> {
  VideoPlayerController? _ctrl;
  bool _playFailed = false;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) _initVideo();
  }

  Future<void> _initVideo() async {
    final ctrl = VideoPlayerController.file(File(widget.file.path));
    _ctrl = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {});
      unawaited(ctrl.play());
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
    } catch (_) {
      if (mounted) setState(() => _playFailed = true);
    }
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _playFailed) return;
    if (ctrl.value.isPlaying) {
      unawaited(ctrl.pause());
    } else if (ctrl.value.isCompleted ||
        ctrl.value.position >= ctrl.value.duration) {
      ctrl.seekTo(Duration.zero).then((_) => ctrl.play());
    } else {
      unawaited(ctrl.play());
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final ctrl = _ctrl;
    final ready = ctrl != null && ctrl.value.isInitialized && !_playFailed;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 画面
          if (widget.isVideo)
            GestureDetector(
              onTap: _togglePlay,
              behavior: HitTestBehavior.opaque,
              child: Center(
                child: ready
                    ? AspectRatio(
                        aspectRatio: ctrl.value.aspectRatio,
                        child: VideoPlayer(ctrl),
                      )
                    : _playFailed
                        ? Text(t('momentsVideoPlayFailed'),
                            style:
                                const TextStyle(color: Colors.white54))
                        : const CircularProgressIndicator(
                            color: Colors.white70),
              ),
            )
          else
            Center(
              child: Image.file(File(widget.file.path),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: Colors.white38)),
            ),
          // 视频暂停/重播中心图标
          if (widget.isVideo &&
              ready &&
              !ctrl.value.isPlaying)
            Center(
              child: IgnorePointer(
                child: Icon(
                  ctrl.value.isCompleted ||
                          ctrl.value.position >= ctrl.value.duration
                      ? Icons.replay_circle_filled
                      : Icons.play_circle_fill,
                  size: 64,
                  color: Colors.white70,
                ),
              ),
            ),
          // 左上角 X 关闭（等同重拍：返回拍摄页）
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, size: 26, color: Colors.white),
              ),
            ),
          ),
          // 右下角 重拍 / 确认
          SafeArea(
            child: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16, bottom: 16),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                          foregroundColor: Colors.white),
                      child: Text(t('momentsCameraRetake'),
                          style: const TextStyle(fontSize: 15)),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                          context,
                          CameraCaptureResult(
                              file: widget.file, isVideo: widget.isVideo)),
                      style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF07C160),
                          foregroundColor: Colors.white),
                      child: Text(t('momentsCameraConfirm'),
                          style: const TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
