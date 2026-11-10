/// 意图+2026-11-08（需求2）：H5 选点地图的**非 web 构建空实现**（条件导入桩）。
///
/// location_picker_page.dart 顶部：
///   import 'location_picker_web_stub.dart' if (dart.library.html) 'location_picker_web_impl.dart'
/// 非 web 构建（APK/IPA）解析到本文件——真实实现里 import 了 dart:html /
/// dart:ui_web（web 专有库），APK 构建绝不能触及，故用本桩占位。
/// 运行时入口 buildWebMapPicker 只会在 kIsWeb 分支被调用，非 web 下永远不会
/// 执行到这里，返回空占位 Widget 即可。
library;

import 'package:flutter/material.dart';

/// 空实现：非 web 构建不会被调用（调用点在 kIsWeb 分支内）
Widget buildWebMapPicker({
  required bool isAmap,
  required String jsKey,
  required String jscode,
  required String lang,
  required void Function(Map<String, dynamic>) onMessage,
}) {
  return const SizedBox.shrink();
}

/// 空实现：非 web 构建不会被调用（与 web_impl 的 disposeWebMapPicker 对齐）
void disposeWebMapPicker() {}
