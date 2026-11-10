/// 意图+2026-11-08（需求2）：H5 构建专用的位置选点地图实现。
///
/// webview_flutter 在 web 平台运行时不可用，H5 下改用 HtmlElementView 平台视图
/// 直接嵌入地图 JS API（高德 AMap JS 2.0 / 谷歌 Maps JS API，按引擎分流）。
/// 本文件 import 了 dart:html / dart:ui_web（web 专有库），**只能**经
/// location_picker_page.dart 顶部的条件导入在 web 构建中编译：
///   import 'location_picker_web_stub.dart' if (dart.library.html) 'location_picker_web_impl.dart'
/// 非 web 构建编译的是同目录 location_picker_web_stub.dart 的空实现，dart:html
/// 不会被 APK 构建触及。
///
/// 交互与 App 版 WebView 选点一致：地图中心固定一枚大头针，拖动选点，停稳后
/// 反解地名并回传；JS→Dart 桥用挂在 window 上的回调函数（cbName 按视图实例编号
/// 唯一，支持同页多次打开选点）。回传 JSON 与 WebView 版 LocationBridge 通道
/// 完全同构：{lat,lng,name,address} 之外额外携带 {province,city,district,country}
/// （朋友圈地图选点回填省市区用，聊天发送路径只取前四个字段，互不影响）。
// ignore_for_file: avoid_web_libraries_in_flutter
library;

import 'dart:convert';
import 'dart:html' as html;
// JS→Dart 桥走 dart:js（dart:html 的 Window 索引赋值在 analyzer 下不可用）
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

/// 实例计数：保证同一页面多次打开选点时 viewType / 回调名 / DOM id 唯一
int _seq = 0;
/// 最近一次创建的选点实例回调名（disposeWebMapPicker 恢复 alert/onerror 用）
String? _lastCbName;

/// 创建 H5 选点地图（注册平台视图并返回 HtmlElementView）。
///
/// [onMessage] 与 WebView 版 JS 通道同构：收到
///   - {lat,lng,name,address,province,city,district,country} —— 最新选点；
///   - {amapAlert: '...'} —— 高德鉴权/运行时错误（对照后台配置排查）；
///   - {authFailed: true} —— 谷歌 gm_authFailure；
///   - {geoFailed: ...} —— 定位失败（不阻断选点）。
Widget buildWebMapPicker({
  required bool isAmap,
  required String jsKey,
  required String jscode,
  required String lang,
  required void Function(Map<String, dynamic>) onMessage,
}) {
  final id = ++_seq;
  final viewType = 'location_picker_web_$id';
  // JS→Dart 桥：Dart 闭包挂到 window，JS 侧直接调用（dart2js 自动 allowInterop）
  final cbName = 'locationPickCallback$id';
  _lastCbName = cbName;
  // JS 侧直接调用（dart:js 赋值时自动 allowInterop 包装 Dart 闭包）
  js.context[cbName] = (dynamic payload) {
    try {
      final s = payload?.toString() ?? '';
      final j = jsonDecode(s);
      if (j is Map) onMessage(Map<String, dynamic>.from(j));
    } catch (_) {/* 非 JSON 消息忽略 */}
  };

  ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
    return _buildContainer(
      viewId: viewId,
      isAmap: isAmap,
      jsKey: jsKey,
      jscode: jscode,
      lang: lang,
      cbName: cbName,
    );
  });

  return HtmlElementView(viewType: viewType);
}

/// 意图+2026-11-08（QA 修复）：选点页 pop/dispose 时调用——还原全局
/// alert/onerror 原引用（仅当本实例持有劫持权时，幂等可重复调用）。
/// 调用方：location_picker_page 的 State.dispose（kIsWeb 分支）。
void disposeWebMapPicker() {
  final cb = _lastCbName;
  if (cb == null) return;
  _lastCbName = null;
  _injectPageJs('var h = window.__locHook;'
      'if (h && h.target === "$cb") {'
      'h.target = null;'
      'if (h.origAlert) window.alert = h.origAlert;'
      'if (h.origOnerror) window.onerror = h.origOnerror;'
      'window.__locHook = null;'
      '}');
}

/// 组装地图容器 DOM：#map 容器 + 固定中心大头针 + 按引擎注入 JS API 脚本
html.Element _buildContainer({
  required int viewId,
  required bool isAmap,
  required String jsKey,
  required String jscode,
  required String lang,
  required String cbName,
}) {
  final root = html.DivElement()
    ..style.width = '100%'
    ..style.height = '100%'
    ..style.position = 'relative'
    ..style.overflow = 'hidden'
    ..style.backgroundColor = '#E8EAED';

  final mapDiv = html.DivElement()
    ..id = 'loc_map_$viewId'
    ..style.width = '100%'
    ..style.height = '100%';
  root.append(mapDiv);  // 大头针样式（scoped id 防多实例串样式）
  root.append(html.StyleElement()
    ..text = '#loc_pin_$viewId{position:absolute;left:50%;top:50%;'
        'transform:translate(-50%,-100%);z-index:9;pointer-events:none;'
        'filter:drop-shadow(0 2px 3px rgba(0,0,0,.4))}'
        '#loc_pin_$viewId svg{width:34px;height:44px}');
  final pin = html.DivElement()..id = 'loc_pin_$viewId';
  pin.setInnerHtml(_pinSvg, validator: html.NodeValidatorBuilder()..allowSvg());
  root.append(pin);

  if (isAmap) {
    // 高德：安全密钥必须先于 JS API 脚本注入（校验时机），与 WebView 版一致；
    // 2.0 多数鉴权错误不弹 alert 只打 console → 劫持 alert/onerror 兜底上报。
    // 2026-11-08（QA 修复）：劫持是**全局**的，改为「可恢复 + 幂等 + 保留原行为」——
    //   - __locHook 只装一次（多次进入选点页不叠加劫持）；
    //   - 劫持版先转发给当前选点实例的桥（__locHook.target 动态指向最新实例），
    //     再调用原函数（全站 alert 弹窗、onerror 默认处理不被吞）；
    //   - 页面 pop 时 disposeWebMapPicker() 还原原引用（仅当前实例持有者可还原）。
    final sec = html.ScriptElement()
      ..text = 'window._AMapSecurityConfig = { securityJsCode: ${jsonEncode(jscode)} };'
          'if (!window.__locHook) {'
          'window.__locHook = { origAlert: window.alert, origOnerror: window.onerror, target: null };'
          'window.alert = function(msg){'
          'try { var h = window.__locHook; if (h && h.target) window[h.target](JSON.stringify({amapAlert: String(msg)})); } catch(e){}'
          'var o = window.__locHook && window.__locHook.origAlert; if (o) o.call(window, msg);'
          '};'
          'window.onerror = function(){'
          'try { var h = window.__locHook; if (h && h.target) window[h.target](JSON.stringify({amapAlert: "JS: " + String(arguments[0])})); } catch(e){}'
          'var o = window.__locHook && window.__locHook.origOnerror; if (o) return o.apply(window, arguments);'
          '};'
          '}'
          'window.__locHook.target = "$cbName";';
    html.document.body?.append(sec);
    final api = html.ScriptElement()
      ..src =
          'https://webapi.amap.com/maps?v=2.0&key=$jsKey&plugin=AMap.Geocoder,AMap.Geolocation';
    api.onLoad.listen((_) => _injectPageJs(_amapPageJs(viewId, cbName)));
    api.onError.listen((_) =>
        _injectPageJs("$cbName(JSON.stringify({amapAlert:'AMAP_JS_NOT_LOADED'}));"));
    html.document.body?.append(api);
  } else {
    // 谷歌：Maps JS API（浏览器直开无 WebView 授权问题），key 校验失败走
    // gm_authFailure 回调（与 WebView 版同构）
    final api = html.ScriptElement()
      ..src = 'https://maps.googleapis.com/maps/api/js?key=$jsKey&language=$lang';
    api.onLoad.listen((_) => _injectPageJs(_googlePageJs(viewId, cbName, lang)));
    api.onError.listen((_) => _injectPageJs("$cbName(JSON.stringify({authFailed:true}));"));
    html.document.body?.append(api);
  }
  return root;
}

/// 追加一段内联 JS 并立即执行
void _injectPageJs(String code) {
  html.document.body?.append(html.ScriptElement()..text = code);
}

/// 中心固定大头针（与 WebView 版同款 SVG）
const String _pinSvg =
    '<svg viewBox="0 0 24 24" fill="#EA4335"><path d="M12 0C7 0 3.4 3.8 3.4 8.6 '
    '3.4 15 12 24 12 24s8.6-9 8.6-15.4C20.6 3.8 17 0 12 0zm0 12.2a3.6 3.6 0 1 1 '
    '0-7.2 3.6 3.6 0 0 1 0 7.2z"/></svg>';

/// 把「回传桥」定义为页面级函数，内联 JS 统一走 _post(JSON 字符串)。
/// 2026-11-08（QA）：恢复 lastJson 去重——同一点位重复反解/回调只在 Dart 侧
/// setState 一次（lastJson 由各引擎页面脚本声明，同 script 作用域 var 提升可达）。
String _cbJs(String cbName) => '''
function _post(j){ try { $cbName(j); } catch(e){} }
function _pick(loc, name, addr, prov, city, dist, country){
  var j = JSON.stringify({lat:loc.lat, lng:loc.lng, name:name, address:addr,
    province:prov||'', city:city||'', district:dist||'', country:country||''});
  if (j === lastJson) return;
  lastJson = j;
  _post(j);
}
''';

/// 高德引擎页面逻辑：moveend 停稳反解中心点；addressComponent 取省市区
/// （直辖市 city 为空数组 → 用省名兜底；district/city 非字符串同样兜空）。
/// 定位用 AMap.Geolocation 插件（浏览器下走 HTML5 geolocation/IP 定位，失败不阻断）。
String _amapPageJs(int viewId, String cbName) {
  return '''${_cbJs(cbName)}
var map, geocoder, lastJson='', mapReady=false;
function init(){
  if (typeof AMap === 'undefined') { _post(JSON.stringify({amapAlert:'AMAP_JS_NOT_LOADED'})); return; }
  map = new AMap.Map('loc_map_$viewId', { zoom:15, center:[121.4737,31.2304], viewMode:'2D' });
  // complete = 底图瓦片加载成功（隐含 Key+安全密钥校验通过）
  map.on('complete', function(){ mapReady = true; });
  // 15 秒瓦片仍未加载 = 大概率 Key 类型不对，超时上报显性化（与 WebView 版一致）
  setTimeout(function(){
    if (!mapReady) _post(JSON.stringify({amapAlert:'AMAP_TILES_NOT_LOADED'}));
  }, 15000);
  geocoder = new AMap.Geocoder({});
  map.on('moveend', reverse);
  try {
    new AMap.Geolocation({ enableHighAccuracy:true, timeout:8000 })
      .getCurrentPosition(function(status, result){
        if (status === 'complete' && result && result.position) {
          map.setCenter([result.position.lng, result.position.lat]);
        } else {
          _post(JSON.stringify({geoFailed: (result && result.info) || 'error'}));
        }
      });
  } catch(e){}
  reverse();
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.getLat(), lng:c.getLng()};
  var j = loc.lat + ',' + loc.lng;
  geocoder.getAddress([loc.lng, loc.lat], function(status, result){
    if (status === 'complete' && result && result.regeocode) {
      var rg = result.regeocode;
      var addr = rg.formattedAddress || '';
      var name = '';
      if (rg.pois && rg.pois.length && rg.pois[0].name) name = rg.pois[0].name;
      else if (rg.aois && rg.aois.length && rg.aois[0].name) name = rg.aois[0].name;
      // 省市区（朋友圈地图选点回填用）：直辖市 city 是空数组 → 省名兜底
      var comp = rg.addressComponent || {};
      var prov = typeof comp.province === 'string' ? comp.province : '';
      var city = typeof comp.city === 'string' ? comp.city : '';
      var dist = typeof comp.district === 'string' ? comp.district : '';
      if (!city && prov) city = prov;
      _pick(loc, name, addr, prov, city, dist, typeof comp.country === 'string' ? comp.country : '');
    } else {
      if (status === 'error') {
        var detail = '';
        try { detail = JSON.stringify(result) || ''; } catch(e){}
        _post(JSON.stringify({amapAlert: detail ? detail : 'RE_GEO_EMPTY'}));
      }
      _pick(loc, '', '', '', '', '', '');
    }
  });
}
// H5 下选点页进入时 window load 已触发 → 直接初始化（AMap 全局已就绪）
if (typeof AMap !== 'undefined') init();
''';
}

/// 谷歌引擎页面逻辑（与 WebView 版反解口径一致，address_components 额外解析
/// 省 = administrative_area_level_1 / 市 = locality（缺则 area_level_2）/
/// 区 = sublocality_level_1 / 国家 = country）
String _googlePageJs(int viewId, String cbName, String lang) {
  return '''${_cbJs(cbName)}
var map, geocoder, timer=null, lastJson='';
function init(){
  map = new google.maps.Map(document.getElementById('loc_map_$viewId'), {
    center:{lat:31.2304,lng:121.4737}, zoom:15, disableDefaultUI:true,
    zoomControl:true, clickableIcons:false
  });
  geocoder = new google.maps.Geocoder();
  map.addListener('center_changed', function(){
    if (timer) clearTimeout(timer);
    timer = setTimeout(reverse, 400);
  });
  try {
    navigator.geolocation.getCurrentPosition(function(p){
      map.setCenter({lat:p.coords.latitude, lng:p.coords.longitude});
    }, function(err){
      _post(JSON.stringify({geoFailed: (err && err.code) || -1}));
    }, {enableHighAccuracy:true, timeout:8000, maximumAge:30000});
  } catch(e){}
  reverse();
}
function compOf(comps, type){
  for (var i=0;i<comps.length;i++){
    var types = comps[i].types || [];
    if (types.indexOf(type)>=0) return comps[i].long_name || '';
  }
  return '';
}
function reverse(){
  var c = map.getCenter();
  var loc = {lat:c.lat(), lng:c.lng()};
  geocoder.geocode({location:loc, language:'$lang'}, function(res, st){
    if (st === 'OK' && res && res.length){
      var a = res[0].formatted_address || '';
      var comps = res[0].address_components || [];
      var n = '';
      for (var i=0;i<comps.length;i++){
        var types = comps[i].types || [];
        if (types.indexOf('point_of_interest')>=0 || types.indexOf('establishment')>=0 ||
            types.indexOf('premise')>=0 || types.indexOf('sublocality')>=0){
          n = comps[i].short_name || ''; break;
        }
      }
      if (!n && comps.length) n = comps[0].short_name || '';
      var prov = compOf(comps, 'administrative_area_level_1');
      var city = compOf(comps, 'locality') || compOf(comps, 'administrative_area_level_2');
      var dist = compOf(comps, 'sublocality_level_1');
      var country = compOf(comps, 'country');
      _pick(loc, n, a, prov, city, dist, country);
    } else { _pick(loc, '', '', '', '', '', ''); }
  });
}
if (typeof google !== 'undefined' && google.maps) init();
''';
}
