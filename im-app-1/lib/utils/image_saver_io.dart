import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// 原生端保存：Android/iOS 写入系统相册（原 image_saver.dart 逻辑迁移）。
///
/// 2026-11-11：推广素材海报（内存字节）保存复用本函数——
/// `ImageSaver.saveBytes` 传 `url = ''`，原生端不读 url，无影响。
Future<bool> saveImageBytes(
    Uint8List? bytes, String fileName, String url) async {
  if (bytes == null || bytes.isEmpty) return false;
  // Android ≤12 写相册需要存储权限；13+ request() 直接返回 denied，不影响保存
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      await Permission.storage.request();
    } catch (_) {
      // 权限插件异常不阻断保存（Android 13+ 无需权限也能写入 MediaStore）
    }
  }
  final r = await ImageGallerySaverPlus.saveImage(bytes, quality: 100);
  // Android 返回 {isSuccess: bool, filePath: String}；iOS 返回保存路径字符串
  if (r is Map) {
    return r['isSuccess'] == true ||
        (r['filePath']?.toString().isNotEmpty ?? false);
  }
  return r != null && r.toString().isNotEmpty;
}

/// 2026-11-11 需求3：网络视频下载并保存到系统相册（朋友圈/聊天视频
/// 播放页「下载」按钮共用）。流式下载落临时文件（视频可能几十 MB，
/// 不整段驻留内存）→ ImageGallerySaverPlus.saveFile 写入 MediaStore。
Future<bool> saveVideoUrl(String fullUrl) async {
  Directory? tmp;
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      try {
        await Permission.storage.request();
      } catch (_) {
        // Android 13+ 无需权限
      }
    }
    tmp = await Directory.systemTemp.createTemp('vidsave');
    final name =
        'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final path = '${tmp.path}${Platform.pathSeparator}$name';
    await Dio().download(fullUrl, path,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 10),
        ));
    final f = File(path);
    if (!await f.exists() || await f.length() == 0) return false;
    final r = await ImageGallerySaverPlus.saveFile(path, name: name);
    if (r is Map) {
      return r['isSuccess'] == true ||
          (r['filePath']?.toString().isNotEmpty ?? false);
    }
    return r != null && r.toString().isNotEmpty;
  } catch (_) {
    return false;
  } finally {
    // 清理临时目录（保存动作已在系统侧复制完成）
    try {
      if (tmp != null && await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    } catch (_) {}
  }
}
