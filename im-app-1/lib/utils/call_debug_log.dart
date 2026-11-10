import 'package:flutter/services.dart';

/// 2026-11-01：通话链路内存日志（release 包看不到 debugPrint，排障专用）。
/// 环形缓冲最多保留 400 条；通话页点状态文字即可把全量日志复制到剪贴板，
/// 用户粘贴发给开发即可定位「进房失败/互不见」类问题。
class CallDebugLog {
  CallDebugLog._();
  static final CallDebugLog instance = CallDebugLog._();

  static const int _max = 400;
  final List<String> _lines = <String>[];
  int _seq = 0;

  void log(String msg) {
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${(now.millisecond % 1000).toString().padLeft(3, '0')}';
    _seq++;
    _lines.add('#$_seq $ts $msg');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
  }

  String text() => _lines.isEmpty ? '(no call logs)' : _lines.join('\n');

  /// 全量复制到系统剪贴板（通话页点状态文字触发）
  Future<void> copy() async {
    await Clipboard.setData(ClipboardData(text: text()));
  }

  void clear() {
    _lines.clear();
    _seq = 0;
  }
}
