import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:video_player/video_player.dart';

/// 2026-11-07 朋友圈视频需求：取本地视频首帧生成封面缩略图（PNG 字节），
/// 同时拿到视频时长。发布朋友圈选视频/拍完视频后调用一次，
/// 缩略图随视频元信息一并上传（moments_post.videos 的 thumb/duration）。
///
/// 实现方式：video_player 初始化后把 VideoPlayer 挂到 root Overlay 的
/// 屏幕外 RepaintBoundary（负坐标，用户不可见但会被绘制），
/// seek 到 0.1s 等首帧渲染完成后 toImage 截取。任何失败都返回 null，
/// 调用方降级为无封面（feed 里显示深色占位 + 播放图标）。
class VideoThumbResult {
  /// 首帧 PNG 字节（失败为 null）
  final Uint8List? bytes;

  /// 视频时长
  final Duration duration;

  const VideoThumbResult({required this.bytes, required this.duration});
}

Future<VideoThumbResult?> captureVideoThumb(
    BuildContext context, String path) async {
  // Web：VideoPlayerController.file 不可用（blob URL），直接降级
  if (kIsWeb) return null;
  VideoPlayerController? controller;
  OverlayEntry? entry;
  final boundaryKey = GlobalKey();
  try {
    controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    final duration = controller.value.duration;

    // 挂到 root Overlay 屏幕外（-300, -300），160x160 足够生成清晰缩略图
    final overlayState = Overlay.of(context, rootOverlay: true);
    entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -300,
        top: -300,
        width: 160,
        height: 160,
        child: RepaintBoundary(
          key: boundaryKey,
          child: VideoPlayer(controller!),
        ),
      ),
    );
    overlayState.insert(entry);

    Uint8List? bytes;
    try {
      // seek 触发首帧解码；再等一小段确保 texture 已绘制到 RepaintBoundary
      await controller.seekTo(const Duration(milliseconds: 100));
      await controller.pause();
      await Future<void>.delayed(const Duration(milliseconds: 350));

      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary != null && !boundary.debugNeedsPaint) {
        final image = await boundary.toImage(pixelRatio: 1.0);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        bytes = data?.buffer.asUint8List();
        image.dispose();
      }
    } catch (_) {
      // 截帧失败：返回无封面结果（时长仍有用）
      bytes = null;
    } finally {
      // insert 与 remove 必须配对，且要在 dispose 控制器前摘掉
      //（OverlayEntry.remove() 是官方 API，OverlayState 上没有 remove 方法）
      try {
        entry.remove();
      } catch (_) {}
    }
    return VideoThumbResult(bytes: bytes, duration: duration);
  } catch (_) {
    // 初始化失败等：静默降级为无封面
    return null;
  } finally {
    unawaited(controller?.dispose());
  }
}
