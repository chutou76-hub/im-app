import '../widgets/app_back_button.dart';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../theme/app_theme.dart';
// H5 选点地图（2026-11-08 需求2）：webview_flutter 在 web 平台运行时不可用，
// kIsWeb 分支改用平台视图内嵌地图 JS API。真实实现只在 web 构建编译（内含
// dart:html / dart:ui_web，APK 构建解析到本桩文件的空实现，互不影响）。
import 'location_picker_web_stub.dart'
    if (dart.library.html) 'location_picker_web_impl.dart' as web_picker;

/// 地图引擎配置（/auth/config 下发，选点页与位置气泡共用，进程内缓存）。
/// 2026-09-22 需求1：后台可选谷歌 / 高德双引擎（sys_config map_engine）。
/// 各 key 为空的行为：
///   - 谷歌引擎：googleMapsApiKey 空 → 选点页提示不可用、气泡回落纯文字卡；
///   - 高德引擎：amapJsKey 空 → 同上；amapWebKey 空 → 仅气泡缩略图回落。
class MapConfig {
  final String engine; // 后台原样下发：'amap' = 高德，其余（含空）= 谷歌
  final String googleKey;
  final String amapJsKey; // 「Web端(JS API)」类型
  final String amapJscode; // 配套安全密钥 securityJsCode（2021-12 后申请必填）
  final String amapWebKey; // 「Web服务」类型，气泡静态图

  const MapConfig({
    this.engine = '',
    this.googleKey = '',
    this.amapJsKey = '',
    this.amapJscode = '',
    this.amapWebKey = '',
  });

  bool get isAmap => engine == 'amap';

  /// 选点页 WebView 用的 JS key（按引擎取对应配置）
  String get jsKey => isAmap ? amapJsKey : googleKey;

  /// 位置气泡静态图用的 key（按引擎取对应配置）
  String get staticKey => isAmap ? amapWebKey : googleKey;

  static MapConfig? _cached;
  static Future<MapConfig> get() async {
    if (_cached != null) return _cached!;
    try {
      final r = await ApiClient.instance.get('/api/v1/auth/config');
      final d = (r.data as Map?)?['data'];
      final m = d is Map ? d : const {};
      _cached = MapConfig(
        engine: (m['mapEngine'] ?? '').toString(),
        googleKey: (m['googleMapsApiKey'] ?? '').toString(),
        amapJsKey: (m['amapJsKey'] ?? '').toString(),
        amapJscode: (m['amapJscode'] ?? '').toString(),
        amapWebKey: (m['amapWebKey'] ?? '').toString(),
      );
    } catch (_) {
      _cached = const MapConfig();
    }
    return _cached!;
  }
}

/// 2026-11-13 修复（问题2/5）：定位失败原因显性化——
/// 此前所有失败一律返回 null，调用方（发布弹层/同城 tab）只能静默兜底，
/// 「权限被永久拒绝」与「GPS 8 秒拿不到 fix」对上层不可区分，用户侧表现为
/// 「未获取到位置/同城永远北京」且无从排查。现在失败时带出 [AmapLocateFailure]，
/// 上层据此 toast 引导去系统设置开权限。
enum AmapLocateFailure {
  /// 非高德引擎或未配 amapWebKey（配置问题，不引导用户）
  notConfigured,

  /// 系统定位服务关闭
  serviceDisabled,

  /// 定位权限被拒（本次拒绝，可再次申请）
  permissionDenied,

  /// 定位权限被永久拒绝（需引导用户去系统设置开启）
  permissionDeniedForever,

  /// GPS 取位失败（超时/无 fix，含 lastKnown 兜底也失败）
  noFix,

  /// 逆地理请求失败或返回异常
  regeoFailed,
}

/// amapLocateRegeo 的返回：place 非空 = 成功；place 为空时 failure 说明原因。
class AmapRegeoResult {
  /// (省, 市, 区)，成功时非空
  final (String, String, String)? place;

  /// 失败原因（成功时为 null）
  final AmapLocateFailure? failure;

  /// 2026-11-13 失败原因细分：高德接口返回的原始错误码/信息
  /// （regeoFailed 时携带，如 USERKEY_PLAT_NOMATCH=Key类型不匹配、
  /// INVALID_USER_KEY=Key无效），用于界面显示精确诊断
  final String? detail;

  const AmapRegeoResult(this.place, [this.failure, this.detail]);

  bool get ok => place != null;
}

/// GPS 定位 + 高德 REST 逆地理 → (省, 市, 区)。
/// 2026-11-08 口径变更：朋友圈发布弹层默认位置由「IP 归属地」升级为
/// 「设备 GPS 定位 + 高德 Web服务逆地理」，IP 归属地降级为解析失败兜底。
/// 2026-11-13 修复（问题2/5）：
///   - timeLimit 8s → 15s（冷启动 GPS 8 秒拿不到 fix 直接抛异常，是
///     「未获取到位置」的高频根因）；
///   - getCurrentPosition 失败时回退 getLastKnownPosition()（系统缓存的
///     最近一次定位，秒回），再失败才判 noFix；
///   - 失败不再无声吞掉：返回 [AmapRegeoResult] 携带 [AmapLocateFailure]，
///     deniedForever 时上层 toast 引导去系统设置。
/// 2026-11-13u 修复：权限请求前置到配置检查之前——后台缺 amap_web_key 时
/// 此前连权限弹窗都不弹（notConfigured 提前 return），表现为「第一次进
/// 朋友圈没有获取位置权限」；现在首次进入必先弹系统权限弹窗。
/// 返回失败（place=null）的情形：
///   - 非高德引擎（谷歌引擎无 Web 服务逆地理，不引入额外依赖）→ notConfigured；
///   - 后台未配 amapWebKey（Web服务 Key）→ notConfigured；
///   - 定位服务关闭 → serviceDisabled；权限被拒/永久拒绝 → permissionDenied*；
///   - 定位超时/无 fix → noFix；
///   - 逆地理请求失败或返回 status != '1' → regeoFailed。
/// 坐标系：geolocator 返回 WGS-84，高德要求 GCJ-02——国内坐标直接送会产生
/// 数百米偏移，但与选点页「高德全境 GCJ-02」的消费口径一致地按原值使用
/// （微信默认定位同为近似级精度，省市区粒度可接受，不做 WGS→GCJ 转换）。
Future<AmapRegeoResult> amapLocateRegeo({
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    // 2026-11-13u 修复：权限请求**前置**——此前配置检查在前，后台缺
    // amap_web_key（Web服务 Key）时直接 return notConfigured，连定位权限
    // 系统弹窗都不会弹（用户实测「第一次进朋友圈没弹位置权限」即此）。
    // 权限与后台配置无关：先进权限流程（首次弹系统弹窗、授权一次永久有效），
    // 再查配置、再 GPS 取位。
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      return const AmapRegeoResult(
          null, AmapLocateFailure.permissionDeniedForever);
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.unableToDetermine) {
      return const AmapRegeoResult(null, AmapLocateFailure.permissionDenied);
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const AmapRegeoResult(null, AmapLocateFailure.serviceDisabled);
    }
    final cfg = await MapConfig.get();
    if (!cfg.isAmap || cfg.amapWebKey.isEmpty) {
      return const AmapRegeoResult(null, AmapLocateFailure.notConfigured);
    }
    // 2026-11-13 修复（问题2/5）：15s 超时 + lastKnown 兜底。
    // 冷启动 GPS 常态 8 秒内拿不到 fix；lastKnown 是系统缓存的最近一次
    // 定位（通常秒回且省市级粒度足够），两级都失败才判 noFix。
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.low,
              timeLimit: Duration(seconds: 15)));
    } catch (_) {
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (_) {
        pos = null;
      }
    }
    if (pos == null) {
      return const AmapRegeoResult(null, AmapLocateFailure.noFix);
    }
    // 2026-11-13 失败原因细分：网络异常与接口拒绝分开——此前外层 catch 把
    // 逆地理请求失败也吞成 noFix（误导为「无GPS信号」）；接口拒绝时抓取
    // 高德 infocode（USERKEY_PLAT_NOMATCH=Key类型不匹配等）带回给上层显示
    final Map resp;
    try {
      final dio = Dio();
      final r = await dio.get('https://restapi.amap.com/v3/geocode/regeo',
          queryParameters: {
            'key': cfg.amapWebKey,
            'location': '${pos.longitude},${pos.latitude}',
          }).timeout(timeout);
      if (r.data is! Map) {
        return const AmapRegeoResult(null, AmapLocateFailure.regeoFailed);
      }
      resp = r.data as Map;
    } catch (_) {
      // 网络异常（超时/DNS/断网）：坐标解析环节失败，非 GPS 问题
      return const AmapRegeoResult(null, AmapLocateFailure.regeoFailed,
          'network');
    }
    if (resp['status'] != '1') {
      final code =
          (resp['infocode'] ?? resp['info'] ?? '').toString().trim();
      debugPrint('[amapLocateRegeo] regeo rejected: infocode=$code');
      return AmapRegeoResult(
          null, AmapLocateFailure.regeoFailed, code.isEmpty ? null : code);
    }
    final d = resp;
    final ac = (d['regeocode'] as Map?)?['addressComponent'];
    if (ac is! Map) {
      return const AmapRegeoResult(null, AmapLocateFailure.regeoFailed);
    }
    // 直辖市/省直辖县：city 会是空数组 []，回退用省份
    String pick(dynamic v, String fallback) {
      final s = v is List ? '' : (v ?? '').toString();
      return s.isEmpty ? fallback : s;
    }
    final prov = pick(ac['province'], '');
    return AmapRegeoResult((prov, pick(ac['city'], prov), pick(ac['district'], '')));
  } catch (_) {
    return const AmapRegeoResult(null, AmapLocateFailure.noFix);
  }
}

/// 位置消息选点页（2026-09-21 需求1，「收藏」入口替换为「位置」）。
///
/// 方案：WebView + 在线地图 JS API（而非原生地图 SDK）：
///   - 引擎由后台 sys_config map_engine 选择（2026-09-22 需求1）：谷歌 / 高德；
///   - key 等配置经 /auth/config **运行时热下发**——原生 SDK 要求 key 烧死在
///     Manifest/Info.plist 里，换 key 要重打包；
///   - webview_flutter 依赖本就存在（发现页网页小程序），零新增原生依赖。
///
/// 交互（微信式，两引擎一致）：地图上固定一枚中心大头针，拖动地图选点；
/// 停稳后反解地名；点「发送」回传 {lat,lng,name,address}。
/// 定位：高德用 AMap.Geolocation 插件、谷歌用 HTML5 geolocation（Android 端
/// 同时申请运行时定位权限并放行 WebView 授权弹窗）；拿不到定位则停在默认
/// 中心让用户手动拖动，不阻断选点。
/// 坐标系备注：高德全境 GCJ-02；谷歌境外 WGS-84、境内同样偏移为 GCJ-02，
/// 消息 content 原样存所选引擎坐标，跳转地图 App 时同系不偏移。
class LocationPickerPage extends StatefulWidget {
  const LocationPickerPage({super.key});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  WebViewController? _controller;
  MapConfig _cfg = const MapConfig();
  bool _loadFailed = false;
  // H5 构建专用：平台视图地图就绪标记（2026-11-08 需求2，_controller 在 web 不建）
  bool _webReady = false;
  // H5 平台视图地图 Widget（2026-11-08 QA 修复：_bootstrap 里只创建一次并复用，
  // 避免 build 里每次 setState 重建实例、重复注入脚本）
  Widget? _webMap;
  // 页面语言（谷歌 Maps JS API 的 language 参数；_bootstrap 里取一次）
  String _lang = 'zh';
  // 地图 Key 校验失败（谷歌 gm_authFailure / 高德 alert 劫持上报）：
  // key 无效 / Key 类型不对 /（谷歌）未启用 API、未绑结算 /（高德）缺 jscode
  bool _authFailed = false;
  // 高德具体错误码（USERKEY_PLAT_NOMATCH / INVALID_USER_SCODE 等），提示条
  // 显示原文便于对照后台配置排查（2026-09-22：2.0 鉴权错多数不弹 alert，
  // 靠 Geocoder 错误回调 + 瓦片超时兜底抓取）
  String _authMsg = '';
  // JS 侧反解后持续回传的最新选点（bridge 是单向的，本地缓存最新值）
  Map<String, dynamic> _picked = {};
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // 1) 拿地图引擎配置（/auth/config 下发，MapConfig 进程内缓存）
    _cfg = await MapConfig.get();
    if (!mounted) return;
    if (_cfg.jsKey.isEmpty) {
      setState(() => _loadFailed = true);
      return;
    }
    _lang = Localizations.localeOf(context).languageCode;
    // 2) H5 分支（2026-11-08 需求2）：不进 WebView 也不申请系统定位权限
    //    （浏览器 geolocation 由地图 JS 内处理），直接建平台视图地图。
    //    Widget 只建一次复用（QA 修复：防 setState 重建重复注入脚本）
    if (kIsWeb) {
      if (mounted) {
        setState(() {
          _webMap = web_picker.buildWebMapPicker(
            isAmap: _cfg.isAmap,
            jsKey: _cfg.jsKey,
            jscode: _cfg.amapJscode,
            lang: _lang,
            onMessage: _handleBridgeMessage,
          );
          _webReady = true;
        });
      }
      return;
    }
    // 3) 定位权限：WebView 里定位会二次弹授权，这里先要系统权限
    try {
      await Permission.locationWhenInUse.request();
    } catch (_) {}
    if (!mounted) return;
    // 4) 组 HTML（按引擎）并建 WebView
    final lang = _lang;
    final html = _cfg.isAmap
        ? _buildAmapHtml(_cfg.amapJsKey, _cfg.amapJscode)
        : _buildGoogleHtml(_cfg.googleKey, lang);
    final wc = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFE8EAED))
      ..setNavigationDelegate(NavigationDelegate(
        onWebResourceError: (_) {
          if (mounted) setState(() => _loadFailed = true);
        },
      ))
      ..addJavaScriptChannel('LocationBridge', onMessageReceived: (msg) {
        try {
          final j = jsonDecode(msg.message);
          if (j is! Map) return;
          _handleBridgeMessage(Map<String, dynamic>.from(j));
        } catch (_) {}
      });
    // Android：放行 H5 geolocation 授权弹窗（不弹 = geolocation 永远失败；
    // 高德走自家 Geolocation 插件不受此影响，放行无副作用）
    try {
      final p = wc.platform;
      if (p is AndroidWebViewController) {
        await p.setGeolocationPermissionsPromptCallbacks(
          onShowPrompt: (params) async => const GeolocationPermissionsResponse(
              allow: true, retain: false),
        );
      }
    } catch (_) {}
    // baseUrl 指到对应地图域，保证 https 安全上下文（定位 API 需要）
    await wc.loadHtmlString(
      html,
      baseUrl: _cfg.isAmap
          ? 'https://webapi.amap.com'
          : 'https://maps.googleapis.com',
    );
    if (!mounted) return;
    setState(() => _controller = wc);
  }

  /// 谷歌引擎 HTML：Maps JS API + Geocoder 反解 + HTML5 geolocation
  static String _buildGoogleHtml(String key, String lang) {
    // HTML 模板里不能出现 '</script>' 之外的 Dart 插值坑：key 直接拼 URL。
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body,#map{height:100%;margin:0;padding:0}
  #pin{position:absolute;left:50%;top:50%;transform:translate(-50%,-100%);z-index:9;
       pointer-events:none;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
  #pin svg{width:34px;height:44px}
</style>
<script src="https://maps.googleapis.com/maps/api/js?key=$key&language=$lang"></script>
</head><body>
<div id="map"></div>
<div id="pin"><svg viewBox="0 0 24 24" fill="#EA4335"><path d="M12 0C7 0 3.4 3.8 3.4 8.6 3.4 15 12 24 12 24s8.6-9 8.6-15.4C20.6 3.8 17 0 12 0zm0 12.2a3.6 3.6 0 1 1 0-7.2 3.6 3.6 0 0 1 0 7.2z"/></svg></div>
<script>
// Key 校验失败回调：key 无效/未启用 API/未绑结算/应用限制不匹配时触发
window.gm_authFailure = function(){
  LocationBridge.postMessage(JSON.stringify({authFailed:true}));
};
var map, geocoder, timer=null, lastJson='';
function init(){
  map = new google.maps.Map(document.getElementById('map'), {
    center:{lat:31.2304,lng:121.4737}, zoom:15, disableDefaultUI:true,
    zoomControl:true, clickableIcons:false
  });
  geocoder = new google.maps.Geocoder();
  // 中心点变化：防抖 400ms，停稳后反解地名并回传
  map.addListener('center_changed', function(){
    if (timer) clearTimeout(timer);
    timer = setTimeout(reverse, 400);
  });
  // 尝试 HTML5 定位（WebView 已放行授权；失败不阻断，留世界视图手动拖）
  try {
    navigator.geolocation.getCurrentPosition(function(p){
      map.setCenter({lat:p.coords.latitude, lng:p.coords.longitude});
    }, function(err){
      // 失败上报诊断（权限被拒 code=1 / 不可用 code=2 / 超时 code=3）
      LocationBridge.postMessage(JSON.stringify({geoFailed: (err && err.code) || -1}));
    }, {enableHighAccuracy:true, timeout:8000, maximumAge:30000});
  } catch(e){}
  reverse();
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.lat(), lng:c.lng()};
  var done = function(name, addr){
    var j = JSON.stringify({lat:loc.lat, lng:loc.lng, name:name, address:addr});
    if (j === lastJson) return; // 没变化不重复回传
    lastJson = j;
    LocationBridge.postMessage(j);
  };
  geocoder.geocode({location:loc, language:'$lang'}, function(res, st){
    if (st === 'OK' && res && res.length){
      var a = res[0].formatted_address || '';
      var n = '';
      var comps = res[0].address_components || [];
      // 短地名优先取 POI/地标级，否则第一个成分
      for (var i=0;i<comps.length;i++){
        var types = comps[i].types || [];
        if (types.indexOf('point_of_interest')>=0 || types.indexOf('establishment')>=0 ||
            types.indexOf('premise')>=0 || types.indexOf('sublocality')>=0){
          n = comps[i].short_name || ''; break;
        }
      }
      if (!n && comps.length) n = comps[0].short_name || '';
      done(n, a);
    } else { done('', ''); }
  });
}
window.addEventListener('load', init);
</script>
</body></html>''';
  }

  /// 高德引擎 HTML：AMap JS API 2.0 + Geocoder 反解 + AMap.Geolocation 定位。
  /// 要点：
  ///   - `_AMapSecurityConfig` 必须在 JS API 脚本之前注入（安全密钥校验时机）；
  ///   - 高德 2.0 多数鉴权错误（USERKEY_PLAT_NOMATCH / INVALID_USER_SCODE）
  ///     **不弹 alert、只打 console**，所以除劫持 alert 外还有三路兜底上报：
  ///     window.onerror / 瓦片 complete 超时 / Geocoder 错误回调带错误码；
  ///   - 坐标经纬序为 [lng, lat]（与谷歌 {lat,lng} 相反，勿混）；
  ///   - moveend = 地图停稳，直接反解中心点（无需再防抖）。
  static String _buildAmapHtml(String key, String jscode) {
    final sc = jsonEncode(jscode); // 注入 JS 字符串做转义
    return '''<!DOCTYPE html>
<html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
<style>
  html,body,#map{height:100%;margin:0;padding:0}
  #pin{position:absolute;left:50%;top:50%;transform:translate(-50%,-100%);z-index:9;
       pointer-events:none;filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}
  #pin svg{width:34px;height:44px}
</style>
<script>
window._AMapSecurityConfig = { securityJsCode: $sc };
window.alert = function(msg){
  try { LocationBridge.postMessage(JSON.stringify({amapAlert: String(msg)})); } catch(e){}
};
// 2.0 鉴权/运行时错误不弹 alert 时经此兜底上报具体错误文本
window.onerror = function(msg){
  try { LocationBridge.postMessage(JSON.stringify({amapAlert: 'JS: ' + String(msg)})); } catch(e){}
};
</script>
<script src="https://webapi.amap.com/maps?v=2.0&key=$key&plugin=AMap.Geocoder,AMap.Geolocation"></script>
</head><body>
<div id="map"></div>
<div id="pin"><svg viewBox="0 0 24 24" fill="#EA4335"><path d="M12 0C7 0 3.4 3.8 3.4 8.6 3.4 15 12 24 12 24s8.6-9 8.6-15.4C20.6 3.8 17 0 12 0zm0 12.2a3.6 3.6 0 1 1 0-7.2 3.6 3.6 0 0 1 0 7.2z"/></svg></div>
<script>
var map, geocoder, lastJson='', mapReady=false;
function init(){
  if (typeof AMap === 'undefined') {
    LocationBridge.postMessage(JSON.stringify({amapAlert: 'AMAP_JS_NOT_LOADED'}));
    return;
  }
  map = new AMap.Map('map', { zoom:15, center:[121.4737,31.2304], viewMode:'2D' });
  // complete = 底图瓦片加载成功（隐含 JS Key+安全密钥校验通过）
  map.on('complete', function(){ mapReady = true; });
  // 15 秒瓦片仍未加载 = 大概率 Key 类型不对（USERKEY_PLAT_NOMATCH 不弹
  // alert 也不报给 Geocoder 之外的通道），超时上报显性化
  setTimeout(function(){
    if (!mapReady) {
      LocationBridge.postMessage(JSON.stringify({amapAlert: 'AMAP_TILES_NOT_LOADED'}));
    }
  }, 15000);
  // 2026-11-08：移除早期 REST 探针（拿 JS Key 调 restapi Web服务接口必回
  // USERKEY_PLAT_NOMATCH，地图配置正确时也误报）；鉴权问题由瓦片超时 +
  // Geocoder 错误回调兜底上报，足够定位。
  geocoder = new AMap.Geocoder({});
  // 中心点停稳：反解地名并回传
  map.on('moveend', reverse);
  // 定位到当前位置（高德 Geolocation 走系统定位，失败不阻断）
  try {
    new AMap.Geolocation({ enableHighAccuracy:true, timeout:8000 })
      .getCurrentPosition(function(status, result){
        if (status === 'complete' && result && result.position) {
          map.setCenter([result.position.lng, result.position.lat]);
        } else {
          LocationBridge.postMessage(JSON.stringify({geoFailed: (result && result.info) || 'error'}));
        }
      });
  } catch(e){}
  reverse();
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.getLat(), lng:c.getLng()};
  var done = function(name, addr){
    var j = JSON.stringify({lat:loc.lat, lng:loc.lng, name:name, address:addr});
    if (j === lastJson) return; // 没变化不重复回传
    lastJson = j;
    LocationBridge.postMessage(j);
  };
  geocoder.getAddress([loc.lng, loc.lat], function(status, result){
    if (status === 'complete' && result && result.regeocode) {
      var rg = result.regeocode;
      var addr = rg.formattedAddress || '';
      // 短地名优先取附近 POI/AOI，否则回落地名地址本身
      var name = '';
      if (rg.pois && rg.pois.length && rg.pois[0].name) name = rg.pois[0].name;
      else if (rg.aois && rg.aois.length && rg.aois[0].name) name = rg.aois[0].name;
      done(name, addr);
    } else {
      // status='error' 时把 result 全量上报：有的失败场景 result 为空
      // （连 info 都没有），只报兜底码定位不了原因；全量 JSON 里若有
      // info/infocode 可直接对照后台配置。'no_data' 是正常无结果，不上报
      if (status === 'error') {
        var detail = '';
        try { detail = JSON.stringify(result) || ''; } catch(e){}
        LocationBridge.postMessage(JSON.stringify({amapAlert: detail ? detail : 'RE_GEO_EMPTY'}));
      }
      done('', '');
    }
  });
}
window.addEventListener('load', init);
</script>
</body></html>''';
  }

  /// JS 通道消息统一处理（WebView 版 LocationBridge 与 H5 版 web_picker 回调
  /// 共用，2026-11-08 需求2：消息结构同构）。
  void _handleBridgeMessage(Map<String, dynamic> j) {
    if (j['authFailed'] == true) {
      // 需求2（2026-09-22）：Google 报「此页面无法正确加载 Google 地图」
      // 时给出可操作提示，而不是让用户对着遮罩猜原因
      debugPrint('[loc] gm_authFailure');
      if (mounted) setState(() => _authFailed = true);
      return;
    }
    if (j['amapAlert'] != null) {
      // 高德 JS API 配置错误（key 无效/类型不对/缺 securityJsCode），
      // 劫持 alert + onerror + Geocoder 错误回调统一上报，页面层显示
      // 具体错误码（对照后台配置排查）
      debugPrint('[loc] amap alert: ${j['amapAlert']}');
      if (mounted) {
        setState(() {
          _authFailed = true;
          _authMsg = j['amapAlert'].toString();
        });
      }
      return;
    }
    if (j['geoFailed'] != null) {
      // 需求3：定位失败（权限被拒/超时/不可用）留诊断日志，
      // 不阻断选点（拿不到定位停在默认中心手动拖）
      debugPrint('[loc] geolocation failed code=${j['geoFailed']}');
      return;
    }
    if (mounted) setState(() => _picked = j);
  }

  /// 意图+2026-11-08（需求2）：H5 分支用平台视图内嵌地图（不建 WebView 控制器）
  Widget _mapView() {
    if (kIsWeb && _webReady) {
      return _webMap ??
          web_picker.buildWebMapPicker(
            isAmap: _cfg.isAmap,
            jsKey: _cfg.jsKey,
            jscode: _cfg.amapJscode,
            lang: _lang,
            onMessage: _handleBridgeMessage,
          );
    }
    return WebViewWidget(controller: _controller!);
  }

  /// 2026-11-08（QA 修复）：页面销毁时还原 H5 全局 alert/onerror 劫持
  /// （真实恢复逻辑在 location_picker_web_impl.disposeWebMapPicker）
  @override
  void dispose() {
    if (kIsWeb) web_picker.disposeWebMapPicker();
    super.dispose();
  }

  Future<void> _send() async {
    if (_picked.isEmpty || _sending) return;
    _sending = true;
    final pid = _picked['lat']?.toString() ?? '';
    if (pid.isEmpty) {
      _sending = false;
      return;
    }
    Navigator.of(context).pop(_picked);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      appBar: AppBar(
        leading: const AppBackButton(),
        title: Text(t('chatLocationTitle')),
        actions: [
          TextButton(
            onPressed: _picked.isEmpty ? null : _send,
            child: Text(t('chatLocationSend'),
                style: TextStyle(
                    color: _picked.isEmpty
                        ? context.cs.onSurfaceVariant
                        : AppTheme.primary)),
          ),
        ],
      ),
      body: Stack(
        children: [
          // web：平台视图内嵌地图；非 web：WebView（两者就绪标记互斥）
          if ((kIsWeb && _webReady) || _controller != null)
            _mapView()
          else if (!_loadFailed)
            const Center(child: CircularProgressIndicator())
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t('chatLocationUnavailable'),
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.cs.onSurfaceVariant)),
              ),
            ),
          // Key 校验失败提示条（需求2：告诉用户后台要配什么，按引擎给指引）
          if (_authFailed)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x33000000),
                        blurRadius: 8,
                        offset: Offset(0, 2))
                  ],
                ),
                child: Text(
                    _cfg.isAmap
                        ? (_authMsg.isNotEmpty
                            ? '${t('chatLocationAmapAuthFailed')}\n${t('chatLocationAmapErrCode')} $_authMsg'
                            : t('chatLocationAmapAuthFailed'))
                        : t('chatLocationAuthFailed'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8A5A00), height: 1.4)),
              ),
            ),
          // 底部当前选点条（微信式）：地名 + 详细地址
          if (_picked.isNotEmpty)
            Positioned(left: 0, right: 0, bottom: 0, child: _pickedBar(t)),
        ],
      ),
    );
  }

  Widget _pickedBar(String Function(String) t) {
    final name = (_picked['name'] ?? '').toString();
    final addr = (_picked['address'] ?? '').toString();
    final title = name.isNotEmpty
        ? name
        : (addr.isNotEmpty ? addr : t('chatLocationUntitled'));
    return Container(
      color: context.cs.surface,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (addr.isNotEmpty && addr != title)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(addr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12, color: context.cs.onSurfaceVariant)),
            ),
        ],
      ),
    );
  }
}
