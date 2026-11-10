import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:zxing2/qrcode.dart';       // QRCodeReader（zxing2.dart 未导出）
import 'package:zxing2/zxing2.dart';      // RGBLuminanceSource/BinaryBitmap/...

/// 图片内二维码/条码识别（2026-10-09）。
///
/// 走 `zxing2`（纯 Dart，Android/iOS 无原生依赖、不增加 APK 体积）。
/// 识别链路：网络图下载为内存字节 → `zxing2` 解码 → 返回首个文本结果。
///
/// 说明：二维码识别在本功能中是**次要能力**，因此失败一律静默返回 null，
/// 由调用方给出统一的「未识别到二维码」提示，不向用户抛异常。
class QrImageReader {
  QrImageReader._();

  /// 下载并识别 [url]；失败（网络/格式/无码）统一返回 null。
  static Future<String?> read(String url) async {
    if (url.trim().isEmpty) return null;
    try {
      final resp = await Dio()
          .get<List<int>>(
            url,
            options: Options(responseType: ResponseType.bytes),
          )
          .timeout(const Duration(seconds: 12));
      final bytes = resp.data;
      if (bytes == null || bytes.isEmpty) return null;
      return await decodeImageBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  /// 从**编码后**的图片字节解码（PNG/JPEG 等）。
  ///
  /// 实现要点（2026-10-09踩坑修正）：
  /// - zxing2 **没有** `decodeBytes()` 顶层函数，也没有 `package:zxing2/qr.dart`
  ///   （该库只有 `zxing2.dart` 与 `qrcode.dart` 两个入口）；
  /// - 必须先自行把字节解码成像素，再构造 `RGBLuminanceSource`；
  /// - 用 Flutter 自带的 `ui.instantiateImageCodec` 解像素，**避免引入 image 包**
  ///   （官方 README 示例依赖 image，但本项目不需要多格式支持，dart:ui 足够且零新依赖）。
  ///
  /// 返回首个非空文本；无码或任何异常统一返回 null（识别是次要能力，不抛）。
  static Future<String?> decodeImageBytes(List<int> bytes) async {
    try {
      // instantiateImageCodec 要求 Uint8List，dio 的 data 声明为 List<int> → 显式转换
      final codec = await ui.instantiateImageCodec(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes));
      final frame = await codec.getNextFrame();
      final img = frame.image;
      final w = img.width;
      final h = img.height;
      if (w <= 0 || h <= 0) {
        img.dispose();
        return null;
      }
      // toByteData 拿到 RGBA8888；每像素 4 字节
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      img.dispose();
      if (data == null) return null;
      final rgba = data.buffer.asUint8List();
      // RGBLuminanceSource 要ARGB 的 Int32List（0xAARRGGBB），且需与 Flutter
      // 的 RGBA 字节序对齐：R 在第0 字节，故按 ABGR 组装
      final pixels = Int32List(w * h);
      for (var i = 0, j = 0; i < pixels.length; i++, j += 4) {
        pixels[i] = (rgba[j] << 16) | (rgba[j + 1] << 8) | rgba[j + 2];
      }
      final source = RGBLuminanceSource(w, h, pixels);
      final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
      final result = QRCodeReader().decode(bitmap);
      final text = result.text ?? '';
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }
}

/// 二维码内容类型（2026-10-09）。
///
/// 支付类二维码（微信/支付宝）需**直接唤起对应 App**，不能落到浏览器：
/// `wxp://` / `weixin://` 是私有 scheme，浏览器无法处理；`https://qr.alipay.com`
/// 虽能浏览器打开，但会先加载网页再二次跳转，链路长且部分机型会被拦。
enum QrKind { wechatPay, alipay, link, userCard, appCode, text }

/// 二维码内容解析结果。
class QrPayload {
  final QrKind kind;

  /// 建议跳转的目标 URI。支付类为 App 唤醒地址；link 为原始 https 链接；
  /// userCard/appCode/text 为 null（不自动跳转，交由调用方弹菜单）。
  final Uri? target;

  const QrPayload._(this.kind, this.target);

  /// 是否为支付类（需要唤起 App 而非浏览器）
  bool get isPayment => kind == QrKind.wechatPay || kind == QrKind.alipay;

  /// 解析二维码内容。
  ///
  /// 覆盖的支付码格式（依据公开资料核实，2026-10-09）：
  /// | 平台 | 前缀 / 域名 |
  /// |---|---|
  /// | 微信收款码 | `wxp://`（早期）、`weixin://wxpay/`、`weixin://dl/` |
  /// | 微信付款码 | 15~16 位纯数字（以 10~15 开头，POS 刷卡码） |
  /// | 支付宝收款码 | `https://qr.alipay.com/`、`render.alipay.com` |
  /// | 支付宝 scheme | `alipays://`、`alipay://` |
  ///
  /// **安全约束**：只认上述**精确前缀 / 精确域名**，不做模糊包含匹配 ——
  /// 否则 `https://evil.com/?x=qr.alipay.com` 这类钓鱼链接会被误判为支付宝码
  /// 并唤起支付宝 App，用户看到的是「真支付宝」界面，极易被骗付款。
  static QrPayload parse(String raw) {
    final s = raw.trim();
    final lower = s.toLowerCase();

    // ---- 微信 ----
    if (lower.startsWith('wxp://') ||
        lower.startsWith('weixin://wxpay/') ||
        lower.startsWith('weixin://dl/')) {
      return QrPayload._(QrKind.wechatPay, Uri.tryParse(s));
    }
    if (_isWechatPayCode(s)) {
      // 纯数字付款码不能直接当 scheme，需借 weixin:// 唤起微信收款入口
      return QrPayload._(
          QrKind.wechatPay, Uri.parse('weixin://dl/business/?t=$s'));
    }

    // ---- 支付宝 ----
    if (lower.startsWith('alipays://') || lower.startsWith('alipay://')) {
      return QrPayload._(QrKind.alipay, Uri.tryParse(s));
    }
    if (_isAlipayCollectUrl(s)) {
      // 支付宝收款码是标准 https：先尝试 alipays:// 直接唤起，失败回落原始 https
      return QrPayload._(QrKind.alipay, Uri.tryParse(s));
    }

    // ---- 普通类型 ----
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return QrPayload._(QrKind.link, Uri.tryParse(s));
    }
    if (lower.startsWith('chatpulse://user')) {
      return QrPayload._(QrKind.userCard, null);
    }
    if (lower.startsWith('chatpulse://')) {
      return QrPayload._(QrKind.appCode, null);
    }
    return QrPayload._(QrKind.text, null);
  }

  /// 支付宝收款码域名：**精确 host 比对**，防钓鱼。
  static bool _isAlipayCollectUrl(String s) {
    final u = Uri.tryParse(s);
    final host = u?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;
    return host == 'qr.alipay.com' || host == 'render.alipay.com';
  }

  /// 微信付款码：15 或 16 位纯数字（以 10~15 开头）。
  /// 支付宝付款码是 2 开头的 18 位数字 —— 这里**不认**，
  /// 避免误当微信而唤起错误 App。
  static bool _isWechatPayCode(String s) {
    if (s.length != 15 && s.length != 16) return false;
    if (!RegExp(r'^\d+$').hasMatch(s)) return false;
    return RegExp(r'^1[0-5]').hasMatch(s);
  }
}