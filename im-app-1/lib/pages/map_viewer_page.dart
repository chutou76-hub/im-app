import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../l10n/app_locale.dart';
import '../theme/app_theme.dart';
import 'location_picker_page.dart'; // MapConfig（引擎/key 与选点页同源复用）

/// 应用内位置查看页（2026-11-13 修复问题4）：
/// 此前点击位置消息直接 launchUrl 跳系统浏览器/外部地图 App（离页体验差）；
/// 现改为应用内 WebView 地图（引擎/key 复用 [MapConfig.get]，与选点页
/// location_picker_page.dart 同源），中心放 marker 展示消息坐标（lat/lng/
/// name/address），只读不选点；顶部返回键 + 底部「用地图 App 打开」按钮
/// （复用原 launchUrl 逻辑，保留跳转能力，微信口径）。
///
/// 坐标系备注：消息 content 原样存的是发送时所选引擎坐标系（高德 GCJ-02 /
/// 谷歌 WGS-84，见 location_picker_page.dart 头注释），查看页用同一引擎渲染
/// 即不偏移；引擎与发送时不一致时的偏差可接受，不做坐标系转换。
///
/// H5（kIsWeb）分支：webview_flutter 在 web 平台不可用，降级为静态地图图
/// （高德 Web服务静态图 / 谷歌静态图，与聊天页位置气泡同源）+「用地图 App
/// 打开」按钮（web 上 launchUrl 落到新标签页打开网页地图）。
class MapViewerPage extends StatefulWidget {
  final double lat;
  final double lng;
  final String name;
  final String address;

  const MapViewerPage({
    super.key,
    required this.lat,
    required this.lng,
    this.name = '',
    this.address = '',
  });

  @override
  State<MapViewerPage> createState() => _MapViewerPageState();
}

class _MapViewerPageState extends State<MapViewerPage> {
  WebViewController? _controller;
  MapConfig _cfg = const MapConfig();
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _cfg = await MapConfig.get();
    if (!mounted) return;
    if (kIsWeb || _cfg.jsKey.isEmpty) {
      // H5 平台 / 未配 JS key：不进 WebView，build 里降级静态图
      if (_cfg.jsKey.isEmpty) setState(() => _loadFailed = true);
      return;
    }
    final html = _cfg.isAmap
        ? _buildAmapHtml(_cfg.amapJsKey, _cfg.amapJscode)
        : _buildGoogleHtml(_cfg.googleKey);
    final wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFE8EAED))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (_) {
          if (mounted) setState(() => _loadFailed = true);
        },
      ));
    // baseUrl 指到对应地图域，保证脚本与瓦片请求域一致
    await wc.loadHtmlString(
      html,
      baseUrl: _cfg.isAmap
          ? 'https://webapi.amap.com'
          : 'https://maps.googleapis.com',
    );
    if (!mounted) return;
    setState(() => _controller = wc);
  }

  /// 谷歌引擎：只读地图 + 固定 marker（无选点、无 geolocation）
  String _buildGoogleHtml(String key) {
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>html,body,#map{height:100%;margin:0;padding:0}</style>
<script src="https://maps.googleapis.com/maps/api/js?key=$key"></script>
</head><body>
<div id="map"></div>
<script>
function init(){
  var pos = {lat:${widget.lat}, lng:${widget.lng}};
  var map = new google.maps.Map(document.getElementById('map'), {
    center: pos, zoom: 16, disableDefaultUI: true, zoomControl: true,
    clickableIcons: false, gestureHandling: 'greedy'
  });
  new google.maps.Marker({ position: pos, map: map });
}
window.addEventListener('load', init);
</script>
</body></html>''';
  }

  /// 高德引擎：只读地图 + 固定 marker（经纬序 [lng, lat]，与选点页一致）
  String _buildAmapHtml(String key, String jscode) {
    final sc = jsonEncode(jscode); // 注入 JS 字符串做转义
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>html,body,#map{height:100%;margin:0;padding:0}</style>
<script>
window._AMapSecurityConfig = { securityJsCode: $sc };
</script>
<script src="https://webapi.amap.com/maps?v=2.0&key=$key"></script>
</head><body>
<div id="map"></div>
<script>
function init(){
  if (typeof AMap === 'undefined') return;
  var map = new AMap.Map('map', { zoom: 16, center:[${widget.lng},${widget.lat}], viewMode:'2D' });
  new AMap.Marker({ position:[${widget.lng},${widget.lat}], map: map });
}
window.addEventListener('load', init);
</script>
</body></html>''';
  }

  /// 底部按钮：用地图 App 打开（复用原 _openExternalMap 逻辑）：
  /// 高德走 uri.amap.com marker 页（GCJ-02 同系不偏移）；
  /// 谷歌走 maps.google.com 搜索页。优先拉起地图 App，回落浏览器。
  Future<void> _openExternalMap() async {
    if (widget.lat == 0 && widget.lng == 0) return;
    final cfg = _cfg;
    final web = cfg.isAmap
        ? Uri.parse('https://uri.amap.com/marker?position=${widget.lng},${widget.lat}'
            '&name=${Uri.encodeComponent(widget.name)}')
        : Uri.parse(
            'https://www.google.com/maps/search/?api=1&query=${widget.lat},${widget.lng}');
    try {
      await launchUrl(web, mode: LaunchMode.externalNonBrowserApplication);
      return;
    } catch (_) {}
    try {
      await launchUrl(web, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// 气泡上的地点标题（name 优先，address 兜底）
  String get _title => widget.name.isNotEmpty
      ? widget.name
      : (widget.address.isNotEmpty ? widget.address : '');

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      backgroundColor: const Color(0xFFE8EAED),
      appBar: AppBar(
        backgroundColor: context.cs.surface,
        foregroundColor: context.cs.onSurface,
        elevation: 0.5,
        title: Text(
          _title.isEmpty ? t('chatLocationUntitled') : _title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _mapArea()),
          // 底部操作条：地点名/地址 + 「用地图 App 打开」（微信口径保留跳转）
          Container(
            width: double.infinity,
            color: context.cs.surface,
            padding: EdgeInsets.fromLTRB(16, 12, 16,
                12 + MediaQuery.of(context).padding.bottom),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_title.isNotEmpty)
                        Text(_title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      if (widget.address.isNotEmpty &&
                          widget.address != _title)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(widget.address,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: context.cs.onSurfaceVariant)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  onPressed: _openExternalMap,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(t('chatLocationOpenExternal'),
                      style: const TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 地图区：原生 WebView / H5 降级静态图 / 加载失败占位
  Widget _mapArea() {
    final wc = _controller;
    if (!kIsWeb && wc != null) {
      return WebViewWidget(controller: wc);
    }
    // H5 / 未配 JS key：静态地图（与聊天页位置气泡同源），点击也可外部打开
    if (kIsWeb && !_loadFailed && (widget.lat != 0 || widget.lng != 0)) {
      final key = _cfg.staticKey;
      if (key.isNotEmpty) {
        final thumb = _cfg.isAmap
            ? 'https://restapi.amap.com/v3/staticmap'
                '?location=${widget.lng},${widget.lat}&zoom=15&size=640*480&scale=2'
                '&markers=mid,0xEA4335,:${widget.lng},${widget.lat}&key=$key'
            : 'https://maps.googleapis.com/maps/api/staticmap'
                '?center=${widget.lat},${widget.lng}&zoom=15&size=640x480&scale=2'
                '&markers=color:0xEA4335%7C${widget.lat},${widget.lng}&key=$key';
        return GestureDetector(
          onTap: _openExternalMap,
          child: Image.network(
            thumb,
            fit: BoxFit.cover,
            width: double.infinity,
            errorBuilder: (_, __, ___) => _placeholder(),
          ),
        );
      }
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: const Color(0xFFE8EAED),
      alignment: Alignment.center,
      child: Icon(Icons.location_on_outlined,
          size: 48, color: Colors.grey.shade600),
    );
  }
}
