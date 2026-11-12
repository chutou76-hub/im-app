import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_locale.dart';
import '../services/api_client.dart';
import '../services/moment_service.dart';
// 2026-10-10 需求3：进入朋友圈清互动未读红点
import '../services/moments_notify_store.dart';
import '../services/user_cache.dart';
import '../services/wide_layout_store.dart';
import '../theme/app_theme.dart';
import '../theme/design2026.dart';
import '../utils/image_saver.dart';
import '../utils/video_thumb.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/brand_loading.dart';
import '../widgets/moment_post_card.dart';
import '../widgets/region_picker_sheet.dart';
import 'city_picker_page.dart';
import 'image_viewer_page.dart';
import 'location_picker_page.dart';
import 'moments_camera_page.dart';
import 'moments_notify_page.dart';
import 'user_profile_page.dart';
import 'video_player_page.dart';

/// 朋友圈评论输入条可见性（2026-11-07 夜5，键盘遮挡兜底）：
/// 全局通知给 home_shell——输入条打开时**直接隐藏**浮动底部导航。
/// 背景：部分机型（客户手机）viewInsets 上报不可靠，仅靠键盘检测
/// 导航仍会压住输入条；输入条打开即隐藏是确定性方案（键盘收起与否无关）。
final ValueNotifier<bool> momentsCommentBarVisible = ValueNotifier(false);

/// 朋友圈（2026-11-07 新版式，对照设计稿 moments.html）：
/// 白底吸顶「朋友圈」标题 + 相机按钮 → surface-2 胶囊「广场/同城/好友」筛选
/// （2026-11-10 三 tab 改版，同城 tab 文案=城市名，默认北京、定位/手动切换）
/// → 互动通知入口卡 → 微信式帖子流（⋯ 展开式赞/评论 + 社交盒）。
/// 数据走后端 /api/v1/moments（含小助手动态、好友动态；被屏蔽的仅自己可见）。
/// 功能逻辑与旧版一致：下拉刷新、点赞/取消、评论（键盘保活）、回复、删帖、
/// 视频发布、审核标识、地区显示。
class MomentsPage extends StatefulWidget {
  /// 指定用户 ID（好友资料页"朋友圈"入口）；为空=我的朋友圈
  final String? userId;
  final String? userName;

  /// 客户定制（验收后丢弃）：作为底部 tab 直接展示朋友圈——
  /// 顶部为「朋友圈」标题 + 发布相机 + 广场/同城/好友切换 + 互动通知入口
  final bool tabMode;
  const MomentsPage({super.key, this.userId, this.userName, this.tabMode = false});

  @override
  State<MomentsPage> createState() => MomentsPageState();
}

/// State 公开（2026-11-07 需求2）：home_shell 用 GlobalKey 转调 tab 切换事件，
/// 实现切走再切回朋友圈 tab 时评论草稿保留 + 恢复键盘焦点。
class MomentsPageState extends State<MomentsPage> {
  final _svc = MomentService.instance;
  bool _loading = true;
  List<Map<String, dynamic>> _posts = [];

  // ===== 2026-11-07 需求2：常驻评论输入条（替代 modal 弹层，键盘/草稿不再被销毁） =====
  /// 当前评论的动态（null=输入条收起）
  Map<String, dynamic>? _commentPost;

  /// 回复目标评论（null=直接评论）
  Map<String, dynamic>? _commentReply;

  /// 输入控制器/FocusNode 常驻 State（不随输入条销毁）→ 刷新、切 tab 草稿不丢
  final TextEditingController _commentCtrl = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  bool _sendingComment = false;

  /// 客户定制（验收后丢弃）：tab 模式的范围切换 0=广场 2=同城 1=好友
  /// 2026-11-07 需求6：scope 改为服务端口径——0=广场（所有用户的朋友圈）、
  /// 1=好友（仅好友动态），切换时重新拉列表（不再前端过滤）
  /// 2026-11-10 三 tab 改版：加 2=同城（服务端按 city 过滤）；
  /// 显示顺序 广场/同城/好友，scope 值不重排（scope=1 语义不变，老客户端兼容）
  int _scope = 0;

  /// 同城 tab 当前城市（2026-11-10 三 tab 改版）：存市全名（北京市/衡阳市，
  /// 与发帖侧高德逆地理口径一致），tab 文案显示时去掉尾部「市」；
  /// 默认北京市，定位成功或手动选择后更新。
  String _cityName = '北京市';

  /// 用户手动选过城市 → 本次会话内定位回填不再覆盖
  bool _cityManual = false;

  // 2026-11-07 需求3：互动通知未读数（scope 切换下方红点通知入口）
  int _notifyUnread = 0;

  // 2026-11-13 需求：互动通知总数（含已读）——为 0 时隐藏「互动通知」入口卡；
  // loaded 标记防首帧闪烁（未拉到数据前保持显示）
  int _notifyTotal = 0;
  bool _notifyLoaded = false;

  // ===== 无限翻页（2026-11-11 修复：广场/同城/好友列表只有 20 条不能上滑翻页）=====
  /// 已加载页码（从 1 起）；[total] 服务端返回的总条数（hasMore 依据）
  int _page = 1;
  int _total = 0;
  bool _loadingMore = false;
  bool _hasMore = true;

  /// 无限翻页（2026-11-11）：滚到列表底部附近自动拉下一页追加。
  /// 防重入（_loadingMore）+ 按 id 去重（防下拉刷新与加载更多并发时重复插入）。
  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = widget.userId != null
          ? await _svc.listByUser(widget.userId!, page: next)
          : await _svc.list(
              page: next,
              scope: _scope,
              city: _scope == 2 ? _cityName : '',
              keyword: _keyword);
      final list = ((data['list'] as List<dynamic>?) ?? [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
      if (mounted) {
        setState(() {
          final seen = _posts.map((p) => '${p['id']}').toSet();
          for (final p in list) {
            if (seen.add('${p['id']}')) _posts.add(p);
          }
          _page = next;
          _total = (data['total'] as num?)?.toInt() ?? _total;
          _hasMore = list.isNotEmpty && _posts.length < _total;
          _loadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  // ===== 2026-11-13 朋友圈内容搜索 =====
  /// 搜索栏是否展开（AppBar 放大镜切换）
  bool _searching = false;

  /// 当前生效的关键词（trim 后；空串=未在搜索，走正常时间线）
  String _keyword = '';
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _searchDebounce; // 输入防抖 500ms，停止输入自动搜

  List<Map<String, dynamic>> get _visiblePosts => _posts;

  @override
  void initState() {
    super.initState();
    _load();
    // 2026-10-10 需求3：进入朋友圈即视为已查看互动（服务端全部置已读，
    // 发现 tab / 朋友圈入口红点随之清零）。仅"我的朋友圈"清——看别人的
    // 朋友圈不产生互动，清了也无害，但语义上自己的时间线才算"看过"
    // 2026-11-07 变更：进入朋友圈不再全部置已读——红点改由 scope 切换下方的
    // 「互动通知」入口承接（微信式），点开通知列表时才 markRead。
    if (widget.userId == null) MomentsNotifyStore.instance.refresh();
    // 2026-11-10 三 tab 改版：进入页面后异步高德定位，定位成功自动把同城
    // tab 名改成所在城市（失败静默保持默认北京市；不阻塞页面加载）
    // 2026-11-13 需求16：定位延后到首帧渲染完成后启动——此前 initState 立即
    // 申请权限时宿主 Activity 尚未就绪，Android 会吞掉系统权限弹窗（用户实测
    // 「进朋友圈不弹位置权限」）；延后启动弹窗稳定弹出，授权后 GPS 定位成功
    // 即自动把城市 tab 改为所在城市
    if (widget.tabMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (mounted && !_cityManual) _autoLocateCity();
        });
      });
    }
  }

  @override
  void dispose() {
    // 2026-11-07 需求2：常驻评论输入条的资源随页面销毁
    momentsCommentBarVisible.value = false; // 夜5：兜底恢复底部导航
    _commentCtrl.dispose();
    _commentFocus.dispose();
    // 2026-11-13 搜索相关资源
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 2026-11-07 需求2：home_shell 切回朋友圈 tab 时转调——
  /// 评论输入条开着则恢复焦点弹键盘（草稿在 State 里，无需恢复文本）
  void onTabReselected() {
    if (_commentPost != null && mounted) {
      _commentFocus.requestFocus();
    }
  }

  /// 2026-11-07 需求2：home_shell 切离朋友圈 tab 时转调——
  /// 收起键盘但保留输入条与草稿（不置空 _commentPost/控制器文本）
  void onTabDeselected() {
    if (_commentPost != null) {
      _commentFocus.unfocus();
    }
  }

  Future<void> _load() async {
    try {
      final data = widget.userId != null
          ? await _svc.listByUser(widget.userId!)
          // 2026-11-10 三 tab 改版：scope=2（同城）带 city 透传服务端过滤，
          // scope=0/1 不带 city（服务端行为不变）
          // 2026-11-13 内容搜索：keyword 非空时服务端在当前 scope 可见性
          // 基础上叠加 content LIKE 过滤
          : await _svc.list(
              scope: _scope,
              city: _scope == 2 ? _cityName : '',
              keyword: _keyword);
      if (mounted) {
        setState(() {
          _posts = ((data['list'] as List<dynamic>?) ?? [])
              .map((e) => (e as Map).cast<String, dynamic>())
              .toList();
          _loading = false;
          // 2026-11-11 无限翻页：刷新语义=回到第 1 页；hasMore 按服务端 total 判定
          _page = 1;
          _total = (data['total'] as num?)?.toInt() ?? _posts.length;
          _hasMore = _posts.length < _total;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // 2026-11-07 需求3：拉互动通知未读数（自己的时间线才有意义）
    // 2026-11-13 需求：同时拿通知总数 total——为 0（一条互动通知都没有）
    // 时隐藏「互动通知」入口卡（loaded 标记防首帧闪烁：未拉到前保持显示）
    if (widget.userId == null) {
      try {
        final n = await _svc.notifyUnread();
        if (mounted) {
          setState(() {
            _notifyUnread = n['unread'] ?? 0;
            _notifyTotal = n['total'] ?? 0;
            _notifyLoaded = true;
          });
        }
      } catch (_) {}
    }
  }

  // ===== 2026-11-13 朋友圈内容搜索 =====

  /// AppBar 放大镜：展开/收起搜索栏；收起时清关键词重拉（回到正常时间线）
  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (_searching) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
        return;
      }
      _searchDebounce?.cancel();
      _searchCtrl.clear();
      if (_keyword.isNotEmpty) {
        _keyword = '';
        _load();
      }
    });
  }

  /// 输入变化：刷新清空按钮显隐 + 500ms 防抖自动搜索
  void _onSearchChanged(String v) {
    setState(() {}); // 末尾清空按钮显隐跟随文本
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), _submitSearch);
  }

  /// 提交搜索：trim 后与现有关键词不同才重拉列表
  void _submitSearch() {
    final kw = _searchCtrl.text.trim();
    if (kw == _keyword) return;
    _keyword = kw;
    _load();
  }

  /// 搜索栏（列表顶部白底胶囊输入框，含放大镜/清空按钮）
  Widget _searchBar() {
    final t = AppLocalizations.of(context).t;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: D2026.outline2),
      ),
      child: Row(children: [
        const Icon(Icons.search, size: 18, color: D2026.text3),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontSize: 14, color: D2026.text1),
            decoration: InputDecoration(
              hintText: t('momentsSearchHint'),
              hintStyle: const TextStyle(fontSize: 14, color: D2026.text3),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _submitSearch(),
          ),
        ),
        if (_searchCtrl.text.isNotEmpty)
          GestureDetector(
            onTap: () {
              _searchCtrl.clear();
              _submitSearch();
              _searchFocus.requestFocus();
            },
            child: const Icon(Icons.close, size: 16, color: D2026.text3),
          ),
        const SizedBox(width: 4),
      ]),
    );
  }

  /// 2026-11-10 三 tab 改版：异步高德定位（GPS + 逆地理，amapLocateRegeo），
  /// 成功且用户未手动选过城市时把同城
  /// tab 名改成定位城市；
  /// 2026-11-13 修复（问题5）：定位失败不再静默停留「北京市」——
  ///   - 权限被永久拒绝（deniedForever）→ toast 引导去系统设置开启定位权限；
  ///   - 其余失败（无 key/服务关闭/GPS 超时/逆地理失败）→ 回退服务端 IP 归属地
  ///     城市（_svc.location() 的 city 字段），仍拿不到才保持默认北京市。
  /// 当前正处于同城 scope 时重拉列表。
  Future<void> _autoLocateCity() async {
    final t = AppLocalizations.of(context).t;
    final r = await amapLocateRegeo();
    if (!mounted) return;
    // 2026-11-13 修复（问题5）：永久拒绝给可操作提示（只提示一次的代价可接受，
    // 用户手动选过城市后本函数不会再覆盖，toast 也不打扰）
    if (r.failure == AmapLocateFailure.permissionDeniedForever) {
      AppDialogs.toast(context, t('locPermDeniedHint'));
      return;
    }
    if (r.place != null && !_cityManual) {
      // amapLocateRegeo 返回 (省, 市, 区)——直辖市 city 已在定位侧用省名兜底
      final city = r.place!.$2.trim();
      if (city.isNotEmpty && city != _cityName) {
        if (!mounted) return;
        setState(() => _cityName = city);
        if (_scope == 2) _load();
      }
      return;
    }
    // 2026-11-13 失败显性化：打印失败原因（notConfigured=后台缺 amap_web_key）
    debugPrint('[moments] autoLocate failed: ${r.failure}');
    // 2026-11-13 修复（问题5）：GPS 失败回退服务端 IP 归属地城市
    if (_cityManual) return;
    try {
      final loc = await _svc.location();
      final city = (loc['city'] ?? '').toString().trim();
      if (city.isEmpty || city == _cityName || !mounted) return;
      setState(() => _cityName = city);
      if (_scope == 2) _load();
    } catch (_) {
      // IP 归属地也失败：保持默认北京市（老口径）
    }
  }

  /// 2026-11-10 三 tab 改版：已激活的同城 tab 再次点击 → 打开城市选择页
  /// （省 → 市两级，数据源复用省市区选择器的 pca.json）。
  /// 选中后更新 _cityName、重拉列表，并标记已手动选择
  /// （本次会话内定位回填不再覆盖）。
  /// 2026-11-13 需求：选择页顶部显示「定位城市」块（GPS→IP 两级，
  /// [locateCityName]），用户先看到定位到的城市再手动切换其他地区。
  /// 2026-11-12 改版：底部弹层（上下堆叠省市、无搜索）改为整屏城市页
  /// [CityPickerPage]（搜索 + 定位 + 热门 + A-Z 索引 + 二级市列表）。
  Future<void> _pickCity() async {
    final city = await CityPickerPage.show(context,
        currentCity: _cityName, locate: locateCityName);
    if (city == null || city.isEmpty || !mounted) return;
    if (city == _cityName) return;
    setState(() {
      _cityName = city;
      _cityManual = true;
      _loading = true;
    });
    _load();
  }

  /// 城市选择器顶部的定位回调：GPS→高德逆地理 → 失败回退服务端 IP 归属地。
  /// 2026-11-13 定位失败显性化：返回 (城市, 失败原因提示) 记录——城市非空即
  /// 成功；失败时 reason 直接显示在定位行（notConfigured=后台缺 amap_web_key
  /// 「Web服务」Key；noFix=无 GPS 信号，模拟器/室内常见），不再只笼统报错。
  Future<(String?, String?)> locateCityName() async {
    final t = AppLocalizations.of(context).t;
    final r = await amapLocateRegeo();
    if (r.place != null) return (r.place!.$2, null);
    debugPrint('[moments] locate failed: ${r.failure} '
        '(notConfigured=后台缺 amap_web_key「Web服务」Key)');
    final hint =
        _locFailText(r.failure, t, detail: r.detail ?? '');
    try {
      final loc = await _svc.location();
      final c = (loc['city'] ?? '').toString().trim();
      if (c.isNotEmpty) return (c, null);
      debugPrint('[moments] IP location fallback empty');
    } catch (_) {}
    return (null, hint);
  }

  /// 2026-11-13 定位失败原因 → 用户可读文案（l10n 四语）。
  /// [detail] 高德原始错误码（regeoFailed 时）：常见码翻译成可操作文案，
  /// 未知码原样显示（与选点页 _authMsg 同思路，原文便于对照排查）
  String _locFailText(AmapLocateFailure? f, String Function(String) t,
      {String detail = ''}) {
    switch (f) {
      case AmapLocateFailure.notConfigured:
        return t('locFailNoKey');
      case AmapLocateFailure.noFix:
        return t('locFailNoFix');
      case AmapLocateFailure.serviceDisabled:
        return t('locFailService');
      case AmapLocateFailure.permissionDenied:
      case AmapLocateFailure.permissionDeniedForever:
        return t('locFailPerm');
      case AmapLocateFailure.regeoFailed:
        final base = t('locFailRegeo');
        if (detail.isEmpty) return base;
        final hint = _amapCodeHint(detail);
        return hint == null ? '$base [$detail]' : '$base（$hint）';
      case null:
        return t('locFailNoFix');
    }
  }

  /// 高德逆地理常见错误码 → 中文可操作提示；未知返回 null（原样显示）
  String? _amapCodeHint(String code) {
    if (code.contains('USERKEY_PLAT_NOMATCH')) {
      return 'Key类型不匹配——你填的是「Web端(JS API)」类型Key，需换「Web服务」类型';
    }
    if (code.contains('INVALID_USER_KEY') || code == '10001') {
      return 'Key无效或未启用，请到高德控制台核对';
    }
    // 2026-11-13 实测用户命中 10005：Web服务 Key 配置了 IP 白名单，
    // 手机/云手机动态出口 IP 不在名单内 → 请求被拒
    if (code.contains('10005') || code.contains('INVALID_USER_IP')) {
      return 'Key的IP白名单限制——到高德控制台该Key的安全设置里清空IP白名单后重试';
    }
    if (code.contains('OVER_LIMIT') || code.contains('OVERQUERY')) {
      return '当日调用配额已用完';
    }
    if (code.contains('SERVICE_NOT_ACCESSIBLE')) {
      return '该Key未开通逆地理服务';
    }
    if (code == 'network') return '网络异常';
    return null;
  }

  /// 同城 tab 文案：市全名去掉尾部「市」（衡阳市→衡阳、北京市→北京，
  /// 用户拍板口径「广场 衡阳 好友」）
  String _cityLabel() {
    final n = _cityName;
    if (n.length > 1 && n.endsWith('市')) return n.substring(0, n.length - 1);
    return n;
  }

  /// 发布入口（2026-11-07 需求3 微信式）：右上角相机 → 底部弹窗两个选项——
  /// 「拍摄」= 微信式拍摄页（短按拍照 / 长按录视频，moments_camera_page.dart）；
  /// 「从手机相册选择」= 二级弹窗 图片（多选，沿用九宫格）/ 视频（单选）。
  /// 视频与图片互斥（微信同款），由发布弹层保证。
  /// 2026-11-07 版式对齐设计稿 sheet 风格（圆角 18 顶部、primary-soft 圆图标行、
  /// surface-2 取消条），交互流程不变。
  Future<void> _publish() async {
    final t = AppLocalizations.of(context).t;
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: D2026.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(t('momentsPickTitle'),
                style: const TextStyle(
                    fontSize: 12, color: D2026.text3)),
            const SizedBox(height: 10),
            _pickRow(ctx, Icons.photo_camera_outlined, t('momentsPickCamera'),
                () => Navigator.pop(ctx, 'camera')),
            _pickRow(ctx, Icons.photo_outlined, t('momentsPickGallery'),
                () => Navigator.pop(ctx, 'gallery')),
            const SizedBox(height: 10),
            _sheetCancel(ctx, () => Navigator.pop(ctx)),
          ]),
        ),
      ),
    );
    if (source == null || !mounted) return;
    if (source == 'camera') {
      // 拍摄：拍出来是照片还是视频由拍摄页决定（短按/长按）
      final result = await Navigator.push<CameraCaptureResult>(
        context,
        MaterialPageRoute(builder: (_) => const MomentsCameraPage()),
      );
      if (result == null || !mounted) return;
      if (result.isVideo) {
        await _publishSheet(video: result.file);
      } else {
        await _publishSheet(images: [result.file]);
      }
      return;
    }
    // 相册：图片（多选）/ 视频（单选）
    final kind = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: D2026.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _pickRow(ctx, Icons.photo_library_outlined,
                t('momentsPickAlbumImages'), () => Navigator.pop(ctx, 'images')),
            _pickRow(ctx, Icons.videocam_outlined, t('momentsPickAlbumVideo'),
                () => Navigator.pop(ctx, 'video')),
            const SizedBox(height: 10),
            _sheetCancel(ctx, () => Navigator.pop(ctx)),
          ]),
        ),
      ),
    );
    if (kind == null || !mounted) return;
    if (kind == 'images') {
      final picked =
          await ImagePicker().pickMultiImage(imageQuality: 80);
      if (picked.isEmpty || !mounted) return;
      await _publishSheet(images: picked);
    } else if (kind == 'video') {
      XFile? x;
      try {
        x = await ImagePicker().pickVideo(source: ImageSource.gallery);
      } catch (_) {
        if (mounted) AppDialogs.toast(context, t('momentsVideoPickFailed'));
        return;
      }
      if (x == null || !mounted) return;
      await _publishSheet(video: x);
    }
  }

  /// 选择弹窗通用行（2026-11-07 对照 sheet-opt：34px primary-soft 圆图标 + 16px 文字）
  Widget _pickRow(BuildContext ctx, IconData icon, String label,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Row(children: [
          Container(
            width: 34,
            height: 34,
            decoration: const BoxDecoration(
                shape: BoxShape.circle, color: D2026.primarySoft),
            child: Icon(icon, size: 18, color: D2026.primary),
          ),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(fontSize: 16, color: D2026.text1)),
        ]),
      ),
    );
  }

  /// 弹层取消条（surface-2 底、圆角 12、高 46、16/600）
  Widget _sheetCancel(BuildContext ctx, VoidCallback onTap) {
    final t = AppLocalizations.of(context).t;
    return Material(
      color: D2026.surface2,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          height: 46,
          alignment: Alignment.center,
          child: Text(t('cancel'),
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: D2026.text1)),
        ),
      ),
    );
  }

  /// 发布弹层（2026-11-07 需求3 扩展视频）：
  /// - images：照片（可多张，九宫格）；video：视频（单选，与照片互斥）
  /// - 选完视频先生成首帧缩略图（feed 封面）并取时长，随发布一并上传
  Future<void> _publishSheet(
      {List<XFile> images = const [], XFile? video}) async {
    final t = AppLocalizations.of(context).t;
    final ctrl = TextEditingController();
    final imgs = List<XFile>.from(images);
    XFile? vid = video;
    // 2026-11-13 定位前置并行（问题13 补充5）：此前 GPS 定位排在「视频抽帧 +
    // IP 预取」之后串行启动——视频发布抽帧耗数秒，定位起步晚，弹层「所在位置」
    // 长时间停留在「未获取到位置」，用户误判定位坏（城市 tab 其实已定位成功）。
    // 现在：GPS 立即启动、IP 归属地预取并行，抽帧与两者同时进行；
    // 弹层定位行新增「定位中…」状态，回填竞态用 gpsFilled/ipDone 门控。
    bool locTouched = false;
    String locFailHint = '';
    bool gpsDone = false, gpsFilled = false, ipDone = false;
    void Function(VoidCallback)? sheetSet; // 弹层 builder 首帧赋值，供异步回填刷新
    BuildContext? sheetCtx;
    void refreshLocRow() {
      final c = sheetCtx;
      if (c != null && c.mounted) sheetSet?.call(() {});
    }
    String province = '';
    String city = '';
    String district = '';
    // GPS 定位（GPS + 高德逆地理）立即启动，不阻塞抽帧
    amapLocateRegeo().then((r) {
      if (!mounted) return;
      gpsDone = true;
      if (r.place != null && !locTouched) {
        // amapLocateRegeo 返回 (省, 市, 区)——直辖市 city 已在定位侧用省名兜底
        gpsFilled = true;
        locFailHint = '';
        province = r.place!.$1;
        city = r.place!.$2;
        district = r.place!.$3;
        refreshLocRow();
        return;
      }
      debugPrint('[moments] publish locate failed: ${r.failure}');
      if (r.failure == AmapLocateFailure.permissionDeniedForever &&
          mounted &&
          !locTouched) {
        AppDialogs.toast(context, t('locPermDeniedHint'));
      }
      // IP 归属地已填则保留其值；全空才显示失败原因
      if (province.isEmpty && city.isEmpty && district.isEmpty) {
        locFailHint = _locFailText(r.failure, t, detail: r.detail ?? '');
      }
      refreshLocRow();
    });
    // 2026-11-07 朋友圈地区需求：预取默认所在地（服务端按请求 IP 归属地解析，
    // ip2region 离线库）；custom=后台「朋友圈地区自定义」开关（开=可改省市区）。
    // 2026-11-08 口径变更：默认位置优先「GPS 定位 + 高德逆地理」，IP 仅兜底；
    // 2026-11-13：两者并行，GPS 已回填则不覆盖（防竞态）
    Map<String, dynamic> loc = {};
    try {
      loc = await _svc.location();
    } catch (_) {}
    ipDone = true;
    final locCustom = loc['custom'] == true;
    if (!gpsFilled) {
      province = (loc['province'] ?? '').toString();
      city = (loc['city'] ?? '').toString();
      district = (loc['district'] ?? '').toString();
      if (province.isNotEmpty || city.isNotEmpty || district.isNotEmpty) {
        locFailHint = ''; // IP 兜底成功，清掉 GPS 失败原因
      }
    }
    refreshLocRow();
    // 视频首帧缩略图（PNG 字节，发布弹层预览与上传复用）+ 时长（秒）
    Uint8List? vidThumb;
    int vidDurationSec = 0;
    if (vid != null && !kIsWeb) {
      final r = await captureVideoThumb(context, vid.path);
      vidThumb = r?.bytes;
      vidDurationSec = r?.duration.inSeconds ?? 0;
    }
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 首帧记录 setSheet/ctx：异步高德定位回填完成时刷新「所在位置」行
          sheetSet = setSheet;
          sheetCtx = ctx;
          return Padding(
          padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('momentsPublishTitle'),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: context.cs.onSurface)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                maxLines: 4,
                autofocus: true,
                style: const TextStyle(fontSize: 15),
                decoration: InputDecoration(
                  hintText: t('momentsThoughtHint'),
                  hintStyle: TextStyle(color: context.cs.onSurfaceVariant),
                  filled: true,
                  fillColor: Theme.of(context).scaffoldBackgroundColor,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              // 媒体区：选了视频只显示视频瓦片（与图片互斥，微信同款）；
              // 否则显示图片九宫格 + 添加瓦片
              if (vid != null)
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 72,
                        height: 72,
                        color: context.cs.surfaceContainer,
                        child: vidThumb != null
                            ? Image.memory(vidThumb,
                                width: 72, height: 72, fit: BoxFit.cover)
                            : Icon(Icons.play_circle_fill,
                                size: 32, color: context.cs.onSurfaceVariant),
                      ),
                    ),
                    // 时长角标
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(D2026.fmtDuration(vidDurationSec),
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white)),
                      ),
                    ),
                    // 删除视频
                    Positioned(
                      right: -8,
                      top: -8,
                      child: InkWell(
                        onTap: () => setSheet(() => vid = null),
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: context.cs.onSurface,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close,
                              size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in imgs)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.file(File(f.path),
                            width: 72, height: 72, fit: BoxFit.cover),
                      ),
                    if (imgs.length < 9)
                      InkWell(
                        onTap: () async {
                          final x = await ImagePicker().pickImage(
                              source: ImageSource.gallery,
                              imageQuality: 80);
                          if (x != null) setSheet(() => imgs.add(x));
                        },
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: context.cs.surfaceContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.add_a_photo_outlined,
                              color: context.cs.onSurfaceVariant),
                        ),
                      ),
                  ],
                ),
              const SizedBox(height: 8),
              // 所在位置（微信式一行）：开关开启→点击弹「地图选点/省市区选择」
              // 双入口；关闭→仅展示默认 IP 位置
              InkWell(
                onTap: !locCustom
                    ? null
                    : () async {
                        final choice = await _locChoiceSheet(ctx);
                        if (choice == 'map') {
                          // 地图选点：复用聊天选点页（App=WebView / H5=平台视图），
                          // 发送时回传 {lat,lng,name,address,province,city,district,country}
                          final picked = await Navigator.of(ctx)
                              .push<Map<String, dynamic>>(MaterialPageRoute(
                                  builder: (_) => const LocationPickerPage()));
                          if (picked != null && ctx.mounted) {
                            locTouched = true; // 手动选过，异步定位回填不再覆盖
                            setSheet(() => _applyPickedLoc(picked,
                                set: (p, c, d) {
                              province = p;
                              city = c;
                              district = d;
                            }));
                          }
                        } else if (choice == 'region') {
                          // 省市区选择：现有三级选择器保留
                          final r = await RegionPickerSheet.show(ctx);
                          if (r != null && ctx.mounted) {
                            locTouched = true; // 手动选过，异步定位回填不再覆盖
                            setSheet(() {
                              province = r[0];
                              city = r[1];
                              district = r[2];
                            });
                          }
                        }
                      },
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Icon(Icons.location_on_outlined,
                        size: 20, color: context.cs.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text(t('momentsLocation'),
                        style: TextStyle(
                            fontSize: 14, color: context.cs.onSurface)),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        _locDisplay(
                            province, city, district, t, locFailHint,
                            !gpsFilled && !(gpsDone && ipDone)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: context.cs.onSurfaceVariant),
                      ),
                    ),
                    if (locCustom)
                      Icon(Icons.chevron_right,
                          size: 20, color: context.cs.onSurfaceVariant),
                  ]),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style:
                      FilledButton.styleFrom(backgroundColor: D2026.primary),
                  child: Text(t('momentsPublish')),
                ),
              ),
            ],
          ),
        );
        },
      ),
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty && imgs.isEmpty && vid == null) {
      AppDialogs.toast(context, t('momentsEmptyContent'));
      return;
    }
    try {
      // 图片先上传（除网络图外逐张走 /upload）。
      // 2026-11-07（QA 修复）：任一张失败不再静默跳过——对齐视频路径，
      // 提示发布失败并中止（避免发出缺图的九宫格让用户误以为发全了）
      final urls = <String>[];
      for (final f in imgs) {
        final url = await _uploadFile(f);
        if (url.isEmpty) {
          if (mounted) AppDialogs.toast(context, t('momentsPublishFailed'));
          return;
        }
        urls.add(url);
      }
      // 视频上传（与图片互斥）+ 缩略图上传 + 时长，组装 videos 元信息。
      // vid 在弹层闭包里可被置空 → 先取本地快照让类型提升生效
      final videoMaps = <Map<String, dynamic>>[];
      final vidFinal = vid;
      if (vidFinal != null) {
        final vurl = await _uploadFile(vidFinal);
        if (vurl.isEmpty) {
          AppDialogs.toast(context, t('momentsPublishFailed'));
          return;
        }
        String thumbUrl = '';
        if (vidThumb != null) {
          try {
            final up = await ApiClient.instance.uploadBytes(
                vidThumb, 'thumb_${DateTime.now().millisecondsSinceEpoch}.jpg',
                dir: 'moments/');
            thumbUrl = (up['url'] ?? '').toString();
          } catch (_) {}
        }
        videoMaps.add({'url': vurl, 'thumb': thumbUrl, 'duration': vidDurationSec});
      }
      await _svc.publish(text, urls,
          videos: videoMaps,
          province: province,
          city: city,
          district: district);
      AppDialogs.toast(context, t('momentsPublished'));
      _load();
    } catch (_) {
      AppDialogs.toast(context, t('momentsPublishFailed'));
    }
  }

  /// 上传任意媒体文件（图片/视频共用，走 /upload，返回 URL；失败空串）
  Future<String> _uploadFile(XFile f) async {
    try {
      final data =
          await ApiClient.instance.uploadXFile(f, f.name, dir: 'moments/');
      return (data['url'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  /// 意图+2026-11-07：三页新版式（对照 moments.html）——白底吸顶标题 +
  /// 34px 圆形相机按钮 + surface-2 胶囊筛选 + 互动通知入口卡 + 微信式帖子流。
  /// tab 模式带筛选与通知入口；他人时间线只带返回键 + 标题 + 帖子流。
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Scaffold(
      // 2026-11-07：页面底与顶栏统一改通讯录头部同款灰 #F5F5F5（用户要求）
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5F5F5),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // tab 模式：无返回键、不自动补 leading，「朋友圈」标题顶到左上角
        automaticallyImplyLeading: !widget.tabMode,
        leading: widget.tabMode
            ? null
            : IconButton(
                // 宽屏右栏打开时不能直接 pop（会弹掉根路由黑屏）→ closeDetail 清右栏
                onPressed: () => closeDetail(context),
                icon: const Icon(Icons.arrow_back_ios_new,
                    size: 20, color: D2026.text2),
              ),
        title: Text(t('discoverMoments'),
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: D2026.text1)),
        centerTitle: false,
        titleSpacing: 16,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: D2026.outline2),
        ),
        actions: [
          // 2026-11-13 朋友圈内容搜索：放大镜展开/收起顶部搜索栏
          //（仅主时间线，查看他人时间线不提供）
          if (widget.userId == null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: InkWell(
                  onTap: _toggleSearch,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: D2026.surface2),
                    child: const Icon(Icons.search,
                        size: 19, color: D2026.text2),
                  ),
                ),
              ),
            ),
          // 仅「我的朋友圈」显示发布相机（34px surface-2 圆钮，对照 cam-btn）
          if (widget.userId == null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: InkWell(
                  onTap: _publish,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: D2026.surface2),
                    child: const Icon(Icons.photo_camera_outlined,
                        size: 18, color: D2026.text2),
                  ),
                ),
              ),
            ),
        ],
      ),
      // 2026-11-07 需求2：评论输入条为 body 内常驻底栏（Column + Expanded），
      // 键盘由 Scaffold resizeToAvoidBottomInset 自动顶起，草稿与焦点由 State 常驻持有
      body: Column(
        children: [
          Expanded(
            // 2026-11-07（夜5）用户补充：评论条打开时点击列表任意空白/卡片区域
            // 即销毁评论条+键盘（微信式点外收起）；translucent 不拦截卡片自身点击
            // 2026-11-07（夜9）用户补充：滑动列表同样销毁评论条+键盘——
            // 否则滑到别条动态再点评论，视觉上还挂在旧输入态看不出效果
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _commentPost != null ? _closeCommentBar : null,
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  // 开始拖动列表（含下拉刷新）即收起评论条与键盘
                  if (n is ScrollStartNotification) {
                    if (_commentPost != null) _closeCommentBar();
                    return false;
                  }
                  // 2026-11-11 无限翻页：滚动更新到距底部 300px 内自动加载下一页
                  // （_loadMore 内部 _loadingMore 防重入，可安全多次触发）
                  if (n is ScrollUpdateNotification &&
                      n.metrics.maxScrollExtent > 0 &&
                      n.metrics.pixels >= n.metrics.maxScrollExtent - 300) {
                    _loadMore();
                  }
                  return false;
                },
                child: RefreshIndicator(
              onRefresh: () => _load(),
              child: CustomScrollView(
                // 2026-11-13：AlwaysScrollableScrollPhysics——列表不满一屏时
                // 默认不可滚动导致 RefreshIndicator 拉不动（广场/同城/好友
                // 都受影响），加 physics 后任何时候都能下拉刷新
                physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics()),
                slivers: [
                  // 2026-11-13 内容搜索：搜索栏展开时置于列表最顶部
                  if (_searching) SliverToBoxAdapter(child: _searchBar()),
                  // 客户定制：tab 模式顶部为「所有人 / 我的好友」切换 + 互动通知入口
                  // 2026-11-13 需求：一条互动通知都没有（total=0，已拉过数据）
                  // 时隐藏入口卡
                  if (widget.tabMode) ...[
                    SliverToBoxAdapter(child: _scopeToggle()),
                    if (!_notifyLoaded || _notifyTotal > 0)
                      SliverToBoxAdapter(child: _notifyEntry()),
                  ],
                  if (_loading)
                    // 骨架屏（2026-09-06）：模拟动态卡布局，替代居中转圈
                    const SliverFillRemaining(
                      child: SkeletonList(style: SkeletonStyle.moments, rows: 4),
                    )
                  else if (_visiblePosts.isEmpty)
                    SliverFillRemaining(
                      child: Center(
                        child: Text(
                            // 2026-11-13：搜索无结果空态优先；
                            // 他人时间线/好友 tab → 好友空态；
                            // 同城 tab（2026-11-10 三 tab）→ 同城空态；其余 → 我的空态
                            _keyword.isNotEmpty
                                ? t('momentsSearchEmpty')
                                : widget.userId != null ||
                                        (widget.tabMode && _scope == 1)
                                    ? t('momentsFriendEmpty')
                                    : widget.tabMode && _scope == 2
                                        ? t('momentsCityEmpty')
                                        : t('momentsMyEmpty'),
                            style: const TextStyle(
                                fontSize: 13, color: D2026.text3)),
                      ),
                    )
                    else
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (ctx, i) => _postCard(_visiblePosts[i]),
                          childCount: _visiblePosts.length,
                        ),
                      ),
                  // 2026-11-11 无限翻页：加载中转圈 / 没有更多提示（列表尾部）
                  if (!_loading && _visiblePosts.isNotEmpty && _loadingMore)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    )
                  else if (!_loading &&
                      _visiblePosts.isNotEmpty &&
                      !_hasMore &&
                      _total > 20)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(t('momentsNoMore'),
                              style: const TextStyle(
                                  fontSize: 12, color: D2026.text3)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            ),
            ),
          ),
          // 评论输入条（2026-11-07 需求2）：仅打开时渲染
          if (_commentPost != null) _commentBar(),
        ],
      ),
    );
  }

  /// 客户定制（验收后丢弃）：朋友圈 tab 顶部的「广场 / 同城 / 好友」胶囊切换
  /// （2026-11-10 三 tab 改版：原「所有人/我的好友」改三枚——中间同城 tab
  /// 文案为当前城市名去掉尾部「市」；已激活时再次点击弹城市选择弹层）。
  /// 意图+2026-11-07：对照 filters——surface-2 轨道整宽、pill 高 34、
  /// 激活态 primary 底白字 + 投影。
  Widget _scopeToggle() {
    final t = AppLocalizations.of(context).t;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: D2026.surface2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(children: [
        Expanded(child: _scopeItem(0, t('momentsScopeAll'))),
        Expanded(child: _scopeItem(2, _cityLabel())),
        Expanded(child: _scopeItem(1, t('momentsScopeFriends'))),
      ]),
    );
  }

  /// 筛选 pill（激活态 primary 底白字 + 阴影；未激活 text-2）
  Widget _scopeItem(int i, String label) {
    final active = _scope == i;
    return GestureDetector(
      onTap: () {
        // 2026-11-10 三 tab 改版：同城 tab 已激活时再次点击 → 弹城市选择
        // 弹层（手动切换城市，选中后重拉列表）
        if (i == 2 && active) {
          _pickCity();
          return;
        }
        // 2026-11-07 需求6：切换 scope 后按服务端口径重新拉列表
        if (_scope != i) {
          setState(() {
            _scope = i;
            _loading = true;
          });
          _load();
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? D2026.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: D2026.primary.withValues(alpha: 0.30),
                      offset: const Offset(0, 4),
                      blurRadius: 12),
                ]
              : null,
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : D2026.text2)),
      ),
    );
  }

  /// 2026-11-07 需求3：互动通知入口卡（对照 notify：白卡 outline-2 边框 +
  /// r-md 圆角 + 卡片阴影，左 30px primary-soft 圆底铃铛，红点在铃铛右上角）。
  /// 点击打开通知列表，返回后刷新未读数。
  Widget _notifyEntry() {
    final t = AppLocalizations.of(context).t;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: D2026.surface,
        borderRadius: BorderRadius.circular(D2026.rMd),
        border: Border.all(color: D2026.outline2),
        boxShadow: D2026.cardShadow,
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(D2026.rMd),
        child: InkWell(
          borderRadius: BorderRadius.circular(D2026.rMd),
          onTap: () async {
            await Navigator.push(context,
                MaterialPageRoute(builder: (_) => const MomentsNotifyPage()));
            if (mounted) {
              setState(() {});
              _load();
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: D2026.primarySoft),
                      child: const Icon(Icons.notifications_none,
                          size: 16, color: D2026.primary),
                    ),
                    // 未读红点（样式沿用旧版计数胶囊，挂铃铛右上角）
                    if (_notifyUnread > 0)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: D2026.error,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: D2026.surface, width: 1.5),
                          ),
                          constraints:
                              const BoxConstraints(minWidth: 16),
                          child: Text(
                            _notifyUnread > 99 ? '99+' : '$_notifyUnread',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 10, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Text(t('momentsNotifyEntry'),
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: D2026.text1)),
                const Spacer(),
                const Icon(Icons.chevron_right,
                    size: 16, color: D2026.text3),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 帖子卡（2026-11-07 新版式）：渲染与点赞/评论交互统一收敛到
  /// MomentPostCard，本页只接线回调（逻辑与旧版一致）。
  Widget _postCard(Map<String, dynamic> p) {
    final name = (p['senderName'] ?? '').toString();
    final avatar = (p['senderAvatar'] ?? '').toString();
    return MomentPostCard(
      post: p,
      avatarSize: 40,
      indent: 52,
      onAvatarTap: p['assistant'] == true
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => UserProfilePage(
                      userId: (p['userId'] ?? '').toString(),
                      name: name,
                      avatar: avatar))),
      onLike: (post) => _toggleLike(post),
      onComment: (post, reply) => _openCommentBar(post, reply: reply),
      onDeleteComment: (post, cid) => _deleteComment(post, cid),
      onDelete: (post, postId) => _deletePost(post, postId),
      onOpenImages: (urls, index) => Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) =>
                  ImageViewerPage(urls: urls, initialIndex: index))),
      onSaveImage: _saveImg,
      onOpenVideo: (url) => Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoPlayerPage(url: url))),
    );
  }

  /// 点赞/取消点赞（原 _postItem 内联逻辑，接线到卡片回调）
  Future<void> _toggleLike(Map<String, dynamic> p) async {
    final id = (p['id'] ?? '').toString();
    final likeCount = (p['likeCount'] as num?)?.toInt() ?? 0;
    try {
      final nowLiked = await _svc.like(id);
      if (mounted) {
        setState(() {
          p['liked'] = nowLiked;
          p['likeCount'] = likeCount + (nowLiked ? 1 : -1);
        });
      }
    } catch (_) {
      if (mounted) {
        AppDialogs.toast(
            context, AppLocalizations.of(context).t('momentsActionFailed'));
      }
    }
  }

  /// 保存九宫格图片到相册（结果轻提示）
  Future<void> _saveImg(String url) async {
    final t = AppLocalizations.of(context).t;
    try {
      final ok = await ImageSaver.saveNetworkImage(url);
      if (!mounted) return;
      AppDialogs.toast(
          context, ok ? t('momentsSaved') : t('momentsSaveFailed'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsSaveFailed'));
    }
  }

  /// 删除自己的评论（服务端确认 + 本地移除）
  Future<void> _deleteComment(Map<String, dynamic> p, String cid) async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('momentsDeleteComment'),
        message: t('momentsDeleteCommentConfirm'),
        danger: true);
    if (ok != true) return;
    try {
      await _svc.deleteComment(cid);
      if (!mounted) return;
      setState(() {
        p['comments'] = ((p['comments'] as List<dynamic>?) ?? [])
            .where((e) => ((e as Map)['id'] ?? '').toString() != cid)
            .toList();
      });
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsActionFailed'));
    }
  }

  /// 打开常驻评论输入条（2026-11-07 需求2，替代原 modal 弹层）：
  /// [reply] 非空 = 回复该评论模式（hint 提示 + 服务端 replyToId）。
  /// 下一帧再请求焦点，保证输入条已挂载、键盘平滑弹出。
  void _openCommentBar(Map<String, dynamic> post, {Map<String, dynamic>? reply}) {
    setState(() {
      _commentPost = post;
      _commentReply = reply;
    });
    momentsCommentBarVisible.value = true; // 夜5：通知 home_shell 隐藏底部导航
    // 回复目标切换时清掉上一条草稿（微信同款：回复即开始新输入）
    if (_commentCtrl.text.isNotEmpty) _commentCtrl.clear();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commentFocus.requestFocus();
    });
  }

  /// 收起评论输入条（点 X）：清空草稿与回复态
  void _closeCommentBar() {
    setState(() {
      _commentPost = null;
      _commentReply = null;
    });
    momentsCommentBarVisible.value = false; // 夜5：恢复底部导航
    _commentCtrl.clear();
    _commentFocus.unfocus();
  }

  /// 发送评论：成功后本地追加展示并**销毁评论输入条+键盘**（2026-11-08
  /// 用户拍板，原「焦点保留可连续评论」口径废弃）；失败提示且不清输入
  Future<void> _sendComment() async {
    final t = AppLocalizations.of(context).t;
    final post = _commentPost;
    final reply = _commentReply;
    if (post == null || _sendingComment) return;
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) {
      AppDialogs.toast(context, t('momentsCommentEmpty'));
      return;
    }
    final replyName = (reply?['senderName'] ?? '').toString();
    final replyId = int.tryParse((reply?['id'] ?? '').toString()) ?? 0;
    setState(() => _sendingComment = true);
    try {
      final data = await _svc.comment((post['id'] ?? '').toString(), text,
          replyToId: replyId);
      if (!mounted) return;
      setState(() {
        final list = ((post['comments'] as List<dynamic>?) ?? []).toList();
        // 服务端返回 {ID, PostID, UserID, Content, CreatedAt}（大写驼峰），
        // 组装成与列表一致的本地 comment map 追加展示
        list.add({
          'id': (data['ID'] ?? data['id'] ?? '').toString(),
          'senderName': _myName(),
          'senderAvatar': (UserCache.myAvatar ?? '').toString(),
          'content': text,
          'createdAt':
              (data['CreatedAt'] ?? data['createdAt'] ?? '').toString(),
          'userId': data['UserID']?.toString() ?? UserCache.myId ?? '',
          if (reply != null) 'replyToName': replyName,
        });
        post['comments'] = list;
        _sendingComment = false;
      });
      // 2026-11-08 用户拍板：发送成功后销毁评论输入条并收起键盘
      // （原「保持焦点连续评论」口径废弃，发送即销毁）
      _closeCommentBar();
    } catch (_) {
      if (mounted) {
        setState(() => _sendingComment = false);
        AppDialogs.toast(context, t('momentsCommentFailed'));
      }
    }
  }

  /// 底部常驻评论输入条（2026-11-07 需求2）。
  /// 意图+2026-11-07：样式对齐设计稿 comment-box——白底、outline 边框圆角 8、
  /// 发送按钮 primary 底白字圆角 8；控制器/FocusNode 由 State 常驻持有，
  /// 下拉刷新、切 tab 回来草稿与键盘不丢（键盘保活机制不变）。
  Widget _commentBar() {
    final t = AppLocalizations.of(context).t;
    final replyName = (_commentReply?['senderName'] ?? '').toString();
    return Container(
      decoration: const BoxDecoration(
        color: D2026.surface,
        border: Border(top: BorderSide(color: D2026.outline2)),
      ),
      padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _commentCtrl,
              focusNode: _commentFocus,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 13, color: D2026.text1),
              decoration: InputDecoration(
                hintText: replyName.isNotEmpty
                    ? '${t('momentsReplyTo')}@$replyName'
                    : t('momentsCommentHint'),
                hintStyle:
                    const TextStyle(fontSize: 12, color: D2026.text3),
                filled: true,
                fillColor: D2026.surface,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: D2026.outline)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: D2026.primary)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 发送按钮（primary 底白字圆角 8，对照 comment-box button）
          Material(
            color: D2026.primary,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _sendingComment ? null : _sendComment,
              child: Container(
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                alignment: Alignment.center,
                child: _sendingComment
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(t('momentsCommentSend'),
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
              ),
            ),
          ),
          // 收起键盘按钮（保留旧版功能）
          IconButton(
            onPressed: _closeCommentBar,
            icon: const Icon(Icons.keyboard_hide,
                size: 20, color: D2026.text3),
            tooltip: t('momentsCommentSend'),
          ),
        ],
      ),
    );
  }

  /// 删除自己的朋友圈动态（2026-11-07 需求2）：确认后调服务端删除并本地移除
  Future<void> _deletePost(Map<String, dynamic> p, String postId) async {
    final t = AppLocalizations.of(context).t;
    final ok = await AppDialogs.confirm(context,
        title: t('momentsDeletePost'),
        message: t('momentsDeletePostConfirm'),
        danger: true);
    if (ok != true) return;
    try {
      await _svc.deletePost(postId);
      if (!mounted) return;
      setState(() {
        _posts.removeWhere(
            (e) => (e['id'] ?? '').toString() == postId);
      });
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsActionFailed'));
    }
  }

  /// 发布弹层「所在位置」行的显示文本：省·市·区 依次拼接；
  /// [locating]=GPS/IP 两路都没返回完 → 显示「定位中…」；
  /// 全空显示「未获取到位置」（2026-11-13：定位失败原因 hint 追加显示）
  String _locDisplay(String p, String c, String d, String Function(String) t,
      [String failHint = '', bool locating = false]) {
    if (locating) return t('locLocating');
    final parts = [p, c, d].where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) {
      return failHint.isEmpty
          ? t('momentsLocationNone')
          : '${t('momentsLocationNone')}·$failHint';
    }
    return parts.join(' · ');
  }

  /// 意图+2026-11-08（需求4）：「所在位置」点击后的微信式双入口底部弹层。
  /// 返回 'map'（地图选点）/ 'region'（省市区选择）/ null（取消）。
  Future<String?> _locChoiceSheet(BuildContext ctx) {
    final t = AppLocalizations.of(ctx).t;
    return showModalBottomSheet<String>(
      context: ctx,
      backgroundColor: ctx.cs.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(t('momentsLocation'),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: sheetCtx.cs.onSurfaceVariant)),
            ),
            _locChoiceTile(sheetCtx, Icons.location_on_outlined,
                t('momentsPickOnMap'), 'map'),
            _locChoiceTile(sheetCtx, Icons.map_outlined,
                t('momentsPickByRegion'), 'region'),
            const SizedBox(height: 8),
            _locChoiceCancel(sheetCtx),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _locChoiceTile(BuildContext ctx, IconData icon, String label, String value) {
    return InkWell(
      onTap: () => Navigator.pop(ctx, value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Icon(icon, size: 22, color: ctx.cs.onSurface),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(fontSize: 15, color: ctx.cs.onSurface)),
        ]),
      ),
    );
  }

  Widget _locChoiceCancel(BuildContext ctx) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: ctx.cs.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          onTap: () => Navigator.pop(ctx),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            height: 46,
            alignment: Alignment.center,
            child: Text(AppLocalizations.of(ctx).t('cancel'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }

  /// 意图+2026-11-08（需求4）：地图选点结果 → 朋友圈省市区回填（不新增字段，
  /// 只映射到 POST /moments 现有 province/city/district）：
  ///   - 中国境外：回填国家名到 province、其余清空（与 IP 归属海外口径一致）；
  ///   - 中国境内：按逆地理 province/city/district 回填（直辖市已在选点侧用
  ///     省名兜底 city）；province 拿不到（反解失败/老数据）时保持原值不动。
  void _applyPickedLoc(Map<String, dynamic> picked,
      {required void Function(String p, String c, String d) set}) {
    final country = (picked['country'] ?? '').toString().trim();
    final p = (picked['province'] ?? '').toString().trim();
    final c = (picked['city'] ?? '').toString().trim();
    final d = (picked['district'] ?? '').toString().trim();
    final isOverseas = country.isNotEmpty &&
        country != '中国' &&
        country.toLowerCase() != 'china';
    if (isOverseas) {
      set(country, '', '');
    } else if (p.isNotEmpty) {
      set(p, c, d);
    }
  }

  /// 当前登录用户昵称（UserCache 资料 nickname 字段，me_page 同款取法）
  String _myName() {
    final prof = UserCache.myProfileData;
    final n = (prof?['nickname'] ?? prof?['name'] ?? '').toString();
    if (n.isNotEmpty) return n;
    return UserCache.myId ?? '';
  }
}
