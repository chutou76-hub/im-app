import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../l10n/app_locale.dart';

/// 朋友圈视频播放页（2026-11-07 需求3，新建简易全屏播放页）：
/// 黑底全屏 video_player，点击画面切换播放/暂停，顶部返回按钮，
/// 初始自动播放，播完停在最后一帧（不循环）。
/// 2026-11-13 修复（问题7）：新增微信式下滑关闭——竖向拖拽跟手位移+渐隐，
/// 松手速度/位移超阈值 pop，否则回弹。交互参数参考 image_viewer_page.dart
/// 的下滑关闭实现（位移/透明度/速度阈值），视频画面比图片高，位移阈值放宽
/// 到 160px。播放器暂停/播放状态不受手势影响（手势只驱动位移，不碰控制器）。
class VideoPlayerPage extends StatefulWidget {
  final String url;
  const VideoPlayerPage({super.key, required this.url});

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with TickerProviderStateMixin {
  VideoPlayerController? _ctrl;
  bool _failed = false;

  // ===== 2026-11-13 修复（问题7）：下滑关闭 =====
  /// 拖拽跟手的垂直位移（正=下滑）；拖拽中整个播放层随手指平移并渐隐
  double _dragDy = 0;

  /// 是否处于下滑拖拽过程（用于背景/浮层联动）
  bool _dragging = false;
  late final AnimationController _snapCtrl;
  Animation<double>? _snapAnim;

  /// 拖拽进度 0~1：320px 拉满，用于背景渐隐与播放层透明度
  double get _dragDim =>
      _dragging ? (_dragDy.abs() / 320).clamp(0.0, 1.0) : 0.0;

  @override
  void initState() {
    super.initState();
    _init();
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    // 回弹动画统一驱动 _dragDy 归零（松手未超阈值时）
    _snapCtrl.addListener(() {
      final a = _snapAnim;
      if (a != null && mounted) setState(() => _dragDy = a.value);
    });
  }

  Future<void> _init() async {
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) return;
      setState(() {});
      unawaited(ctrl.play());
      // 播放结束停在最后一帧并显示重播态（build 里监听 isCompleted）
      ctrl.addListener(() {
        if (mounted) setState(() {});
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _snapCtrl.dispose();
    _ctrl?.dispose();
    super.dispose();
  }

  void _toggle() {
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized || _failed) return;
    if (ctrl.value.isPlaying) {
      unawaited(ctrl.pause());
    } else {
      // 播完后再点 → 从头重播
      if (ctrl.value.isCompleted || ctrl.value.position >= ctrl.value.duration) {
        ctrl.seekTo(Duration.zero).then((_) => ctrl.play());
      } else {
        unawaited(ctrl.play());
      }
    }
    if (mounted) setState(() {});
  }

  // ===== 下滑关闭手势（2026-11-13 问题7）=====
  void _onDragStart(DragStartDetails d) {
    _snapCtrl.stop();
    setState(() {
      _dragging = true;
      _dragDy = 0;
    });
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    setState(() => _dragDy += d.delta.dy);
  }

  /// 松手：视频画面比图片高，位移阈值放宽到 160px（图片看大图是 120px），
  /// 或带甩动速度（>800px/s）则关闭，否则回弹归位
  void _onDragEnd(DragEndDetails d) {
    if (!_dragging) return;
    final v = d.primaryVelocity ?? 0;
    final beyond = _dragDy.abs() > 160;
    final fast = v.abs() > 800;
    if (beyond || fast) {
      Navigator.of(context).pop();
      return;
    }
    // 回弹：从当前位置动画归零，同时退出拖拽态
    _snapAnim = Tween<double>(begin: _dragDy, end: 0).animate(
        CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
    _snapCtrl.reset();
    _snapCtrl.forward().whenComplete(() {
      if (mounted) setState(() => _dragging = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final ctrl = _ctrl;
    final ready = ctrl != null && ctrl.value.isInitialized && !_failed;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        // 竖向拖拽关闭（2026-11-13 问题7）；onTap 播放/暂停由内层 GestureDetector
        // 继续负责——同一手势域里 tap 与 verticalDrag 是独立识别器，互不影响，
        // 暂停状态下拖拽同样可用（不依赖播放状态）
        onVerticalDragStart: _onDragStart,
        onVerticalDragUpdate: _onDragUpdate,
        onVerticalDragEnd: _onDragEnd,
        child: Opacity(
          // 拖拽中播放层整体渐隐
          opacity: 1.0 - _dragDim * 0.6,
          child: Transform.translate(
            offset: Offset(0, _dragDy),
            child: Stack(
              children: [
                // 视频画面（点击切换播放/暂停）
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _toggle,
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: ready
                          ? AspectRatio(
                              aspectRatio: ctrl.value.aspectRatio,
                              child: VideoPlayer(ctrl),
                            )
                          : _failed
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.error_outline,
                                        size: 40, color: Colors.white54),
                                    const SizedBox(height: 10),
                                    Text(t('momentsVideoPlayFailed'),
                                        style: const TextStyle(
                                            fontSize: 14, color: Colors.white54)),
                                  ],
                                )
                              : const CircularProgressIndicator(color: Colors.white70),
                    ),
                  ),
                ),
                // 播放/暂停/重播中心图标（仅暂停或播完时显示）
                if (ready && !ctrl.value.isPlaying)
                  Center(
                    child: IgnorePointer(
                      child: Icon(
                        ctrl.value.isCompleted ||
                                ctrl.value.position >= ctrl.value.duration
                            ? Icons.replay_circle_filled
                            : Icons.play_circle_fill,
                        size: 72,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                // 顶部返回按钮
                SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_ios_new,
                          size: 20, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
