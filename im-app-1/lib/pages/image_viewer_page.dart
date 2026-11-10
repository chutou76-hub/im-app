import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_locale.dart';
import '../services/conversation_service.dart';
import '../services/local_store.dart';
import '../services/user_cache.dart';
import '../utils/image_saver.dart';
import '../utils/qr_image_reader.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/transitions.dart'; // fadeScaleRoute（2026-10-09 补：定位跳转用）
import 'chat_page.dart';
import 'forward_picker_page.dart';

/// 全屏图片预览（微信看大图交互：黑底 + 双指/双击缩放 + 左右滑切换 + 右上角关闭 +
/// 底部「保存到相册」胶囊按钮 / 长按大图保存）。
///
/// 传 [urls]（≥1 张）即可：1 张时自然无页码无可滑动；多图消息点开网格某张时
/// 用 [initialIndex] 定位当前图，左右滑查看上一张/下一张。未传 urls 时用单
/// [url]（老调用兼容）。
class ImageViewerPage extends StatefulWidget {
  /// 单图 url（老调用）；传 urls 时忽略
  final String url;
  final List<String>? urls;
  final int initialIndex;

  /// 2026-10-09 新增（长按图片功能菜单）：来源会话与消息。
  /// 必填的两个参数决定菜单里哪些项可用：
  ///   - [convId]/[msgId] 有值 → 「定位到聊天位置」与「收藏」可用
  ///     （收藏接口是**按消息**收藏，需 convId + msgId）
  ///   - 为空（如头像大图、动态、文件预览等）→ 只保留
  ///     保存/识别二维码/发送给朋友
  final String? convId;
  final String? msgId;

  const ImageViewerPage(
      {super.key,
      this.url = '',
      this.urls,
      this.initialIndex = 0,
      this.convId,
      this.msgId});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with TickerProviderStateMixin {
  late final List<String> _list =
      (widget.urls != null && widget.urls!.isNotEmpty)
          ? List<String>.from(widget.urls!)
          : [widget.url];
  late final PageController _pageCtrl;
  int _index = 0;

  /// 当前页处于缩放态：禁 PageView 横滑，把平移手势留给 InteractiveViewer
  bool _zoomed = false;
  bool _saving = false;

  // ===== 2026-11-07 下滑关闭（微信式看大图） =====
  /// 拖拽跟手的垂直位移（正=下滑）；拖拽中整个图片层随手指平移并轻微缩放
  double _dragDy = 0;

  /// 是否处于下滑拖拽过程（用于背景/浮层联动）
  bool _dragging = false;
  late final AnimationController _snapCtrl;
  Animation<double>? _snapAnim;

  /// 拖拽进度 0~1：300px 拉满，用于浮层渐隐与图片缩放
  double get _dragDim =>
      _dragging ? (_dragDy.abs() / 300).clamp(0.0, 1.0) : 0.0;

  @override
  void initState() {
    super.initState();
    final start = widget.initialIndex.clamp(0, _list.length - 1).toInt();
    _pageCtrl = PageController(initialPage: start);
    _index = start;
    _snapCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    // 回弹动画统一驱动 _dragDy 归零（松手未超阈值时）
    _snapCtrl.addListener(() {
      final a = _snapAnim;
      if (a != null && mounted) setState(() => _dragDy = a.value);
    });
  }

  /// 未缩放态垂直拖拽开始：记录跟手起点（2026-11-07 下滑关闭）
  void _onDragStart(DragStartDetails d) {
    if (_zoomed) return;
    _snapCtrl.stop();
    setState(() {
      _dragging = true;
      _dragDy = 0;
    });
  }

  /// 拖拽跟手：图片随手指平移，浮层同步渐隐（2026-11-07 下滑关闭）
  void _onDragUpdate(DragUpdateDetails d) {
    if (_zoomed || !_dragging) return;
    setState(() => _dragDy += d.delta.dy);
  }

  /// 松手：超过阈值（120px）或带甩动速度则关闭，否则回弹归位（2026-11-07）
  void _onDragEnd(DragEndDetails d) {
    if (_zoomed || !_dragging) return;
    final v = d.primaryVelocity ?? 0;
    final beyond = _dragDy.abs() > 120;
    final fast = v.abs() > 800;
    if (beyond || fast) {
      Navigator.of(context).pop();
      return;
    }
    // 回弹：从当前位置动画归零，同时退出拖拽态
    _snapAnim = Tween<double>(begin: _dragDy, end: 0).animate(
        CurvedAnimation(parent: _snapCtrl, curve: Curves.easeOutCubic));
    _snapCtrl.forward(from: 0).whenComplete(() {
      if (mounted) {
        setState(() {
          _dragging = false;
          _dragDy = 0;
        });
      }
    });
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _snapCtrl.dispose();
    super.dispose();
  }

  String get _currentUrl => _list[_index.clamp(0, _list.length - 1)];

  // ===== 2026-10-09 长按图片功能菜单 =====

  /// 是否来自聊天消息（有 convId + msgId）。
  /// 决定菜单里「定位到聊天位置」「收藏」两项是否可用：
  /// 头像大图 / 动态图 / 文件预览等场景没有消息上下文，只能用通用三项。
  bool get _fromMessage =>
      (widget.convId ?? '').isNotEmpty && (widget.msgId ?? '').isNotEmpty;

  /// 长按当前图：弹底部功能菜单（微信式大图长按）。
  /// 菜单项按可用性裁剪，不做禁用态 —— 不可用的项直接不出现。
  void _showActionMenu() {
    final t = AppLocalizations.of(context).t;
    final items = <_ImgAction>[
      const _ImgAction('save', Icons.save_alt, 'imgActionSave'),
      const _ImgAction('qr', Icons.qr_code_scanner, 'imgActionQr'),
      const _ImgAction('send', Icons.send, 'imgActionSend'),
      if (_fromMessage) ...[
        const _ImgAction('locate', Icons.my_location, 'imgActionLocate'),
        const _ImgAction('fav', Icons.star_border, 'imgActionFavorite'),
      ],
    ];
    AppDialogs.actionSheet(
      context,
      title: t('imgActionTitle'),
      actions: [
        for (final a in items)
          DialogAction(label: t(a.labelKey), icon: a.icon, onTap: () => _run(a.id)),
      ],
    );
  }

  /// 分发菜单动作
  void _run(String id) {
    switch (id) {
      case 'save':
        _save();
        break;
      case 'qr':
        _recognizeQr();
        break;
      case 'send':
        _sendToFriend();
        break;
      case 'locate':
        _locateInChat();
        break;
      case 'fav':
        _favorite();
        break;
    }
  }

  /// 识别图内二维码：下载 → zxing2 解码 → 按内容类型给出后续动作。
  /// 识别是次要能力，任何失败都统一提示「未识别到二维码」，不抛异常。
  bool _qrRunning = false;
  Future<void> _recognizeQr() async {
    if (_qrRunning) return;
    final t = AppLocalizations.of(context).t;
    _qrRunning = true;
    final raw = await QrImageReader.read(_currentUrl);
    if (!mounted) return;
    _qrRunning = false;
    if (raw == null || raw.isEmpty) {
      AppDialogs.toast(context, t('imgQrNotFound'));
      return;
    }
    if (!mounted) return;
    // 2026-10-09：微信/支付宝收款码**直接唤起对应 App**（用户要求）。
    // 支付码是有明确语义的（去付款），再弹菜单等于多一步无谓确认。
    final payload = QrPayload.parse(raw);
    if (payload.isPayment) {
      final app = payload.kind == QrKind.wechatPay ? 'WeChat' : 'Alipay';
      final ok = await _launchApp(payload, raw);
      if (!mounted) return;
      if (!ok) {
        // 未安装该 App：给出明确原因 + 复制兜底（用户可手动粘贴到对应 App）
        await AppDialogs.confirm(
          context,
          title: t('imgQrNoAppTitle', {'app': app}),
          message: t('imgQrNoAppMsg', {'app': app}),
          confirmText: t('imgQrCopyContent'),
          cancelText: t('imgActionCancel'),
        ).then((v) {
          if (v == true) _copyQr(raw);
        });
      }
      return;
    }
    // 非支付码：给「复制 / 打开链接」两个动作
    AppDialogs.actionSheet(
      context,
      title: t('imgQrResultTitle'),
      actions: [
        DialogAction(
            label: t('imgQrCopy'), icon: Icons.copy, onTap: () => _copyQr(raw)),
        if (payload.kind == QrKind.link)
          DialogAction(
              label: t('imgQrOpenLink'),
              icon: Icons.open_in_new,
              onTap: () => _openQr(raw)),
      ],
    );
  }

  /// 唤起微信/支付宝。返回是否成功。
  ///
  /// 微信：`wxp://` / `weixin://` 为私有 scheme，可直接唤起。
  /// 支付宝收款码是 `https://qr.alipay.com/...`，浏览器打开会先加载网页再二次
  /// 跳转，链路长且部分机型被拦；这里先试 `alipays://` 直接唤起，
  /// 失败再回落原始 https（由支付宝服务端返回唤起指令）。
  Future<bool> _launchApp(QrPayload payload, String raw) async {
    final targets = <Uri>[];
    if (payload.kind == QrKind.alipay) {
      final u = Uri.tryParse(raw);
      // alipay:// 协议头 + 其余参数（支付宝两端均支持）
      if (u != null && (u.scheme == 'http' || u.scheme == 'https')) {
        final alipays =
            Uri(scheme: 'alipays', host: u.host, path: u.path, query: u.query);
        targets.add(alipays);
      }
      final orig = payload.target;
      if (orig != null) targets.add(orig);
    } else {
      final t = payload.target;
      if (t != null) targets.add(t);
    }
    for (final u in targets) {
      try {
        final ok = await launchUrl(u,
            mode: LaunchMode.externalNonBrowserApplication);
        if (ok) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _copyQr(String raw) async {
    final t = AppLocalizations.of(context).t;
    await Clipboard.setData(ClipboardData(text: raw));
    if (mounted) AppDialogs.toast(context, t('imgQrCopied'));
  }

  /// 链接类内容用系统浏览器打开（与 chat_page 打开链接同一口径 url_launcher）；
  /// 非 http/https 协议只复制不打开 —— 未知 scheme 丢给系统可能无响应或抛异常。
  Future<void> _openQr(String raw) async {
    final s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      await _copyQr(raw);
      return;
    }
    final t = AppLocalizations.of(context).t;
    try {
      await launchUrl(Uri.parse(s), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('imgQrOpenFailed'));
    }
  }

  /// 「发送给朋友」：复用转发选人页，落到目标会话后按 type=2（图片）发原始 url。
  Future<void> _sendToFriend() async {
    final t = AppLocalizations.of(context).t;
    final myId = UserCache.myId ?? '';
    if (myId.isEmpty) {
      AppDialogs.toast(context, t('imgSendNoLogin'));
      return;
    }
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(builder: (_) => ForwardPickerPage(myId: myId)),
    );
    if (picked == null || !mounted) return;
    final targetId = '${picked['id'] ?? ''}';
    if (targetId.isEmpty) return;
    final svc = ConversationService();
    try {
      String convId;
      if (picked['kind'] == 'group') {
        convId = targetId;
      } else {
        final conv = await svc.createDirect(targetId);
        convId = '${conv['id'] ?? ''}';
      }
      if (convId.isEmpty) throw Exception('no conv');
      await svc.sendRaw(convId, 2, _currentUrl);
      // 记入「最近转发」，与 chat_page 的转发行为一致
      unawaited(LocalStore.addRecentForward(
        kind: '${picked['kind']}',
        id: targetId,
        nickname: '${picked['nickname'] ?? ''}',
        avatar: '${picked['avatar'] ?? ''}',
      ));
      if (mounted) AppDialogs.toast(context, t('imgSendSent'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('imgSendFailed'));
    }
  }

  /// 「定位到聊天位置」（2026-10-09）：回到来源会话并滚动到该消息。
  ///
  /// 实现：`ChatPage` 已有 [ChatPage.scrollToMsgId]（群置顶消息跳转同一机制），
  /// 故这里 pop 掉大图后用该参数重开会话；会话对象取本地会话缓存，避免额外请求。
  /// 宽屏双栏（embedded）下不存在路由栈，此时退化为提示。
  Future<void> _locateInChat() async {
    if (!_fromMessage) return;
    final t = AppLocalizations.of(context).t;
    final nav = Navigator.of(context);
    final convId = widget.convId!;
    final msgId = widget.msgId!;
    final myId = UserCache.myId ?? '';
    if (myId.isEmpty) {
      AppDialogs.toast(context, t('imgLocateNoLogin'));
      return;
    }
    // 退掉大图后再拉会话：来源会话可能已被删除/退群，拉不到就只回首屏
    nav.pop();
    ConvItem? conv;
    try {
      final list = await ConversationService().list();
      for (final c in list) {
        if (c.id == convId) {
          conv = c;
          break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    if (conv == null) {
      AppDialogs.toast(context, t('imgLocateNoConv'));
      return;
    }
    nav.push(fadeScaleRoute(ChatPage(
      conv: conv,
      myId: myId,
      scrollToMsgId: msgId,
    )));
  }

  /// 「收藏」：走按消息收藏接口（convId + msgId）
  Future<void> _favorite() async {
    if (!_fromMessage) return;
    final t = AppLocalizations.of(context).t;
    final ok = await ConversationService()
        .favoriteAdd(widget.convId!, widget.msgId!);
    if (!mounted) return;
    AppDialogs.toast(context, t(ok ? 'imgFavAdded' : 'imgFavFailed'));
  }

  /// 保存当前大图到相册，结果用轻提示反馈
  Future<void> _save() async {
    if (_saving) return;
    final t = AppLocalizations.of(context).t;
    setState(() => _saving = true);
    try {
      final ok = await ImageSaver.saveNetworkImage(_currentUrl);
      if (!mounted) return;
      AppDialogs.toast(
          context, ok ? t('momentsSaved') : t('momentsSaveFailed'));
    } catch (_) {
      if (mounted) AppDialogs.toast(context, t('momentsSaveFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    final multiple = _list.length > 1;
    // 2026-11-07 下滑关闭：拖拽进度驱动图片层平移/缩放与浮层渐隐
    final dim = _dragDim;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 图片层：横向 PageView 翻页；单图只有 1 页（无滑动、无页码）
          // 2026-11-07：包一层 Transform 跟手平移 + 轻微缩放（下滑关闭反馈）
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _dragDy),
              child: Transform.scale(
                scale: 1 - 0.12 * dim,
                child: PageView.builder(
                  controller: _pageCtrl,
                  itemCount: _list.length,
                  // 缩放中禁翻页：平移手势交给 InteractiveViewer 看细节
                  physics: _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  onPageChanged: (i) => setState(() => _index = i),
                  itemBuilder: (context, i) => _ZoomableImage(
                    url: _list[i],
                    onZoom: (v) {
                      if (mounted && v != _zoomed) setState(() => _zoomed = v);
                    },
                    onLongPress: _showActionMenu,
                    // 2026-11-07 下滑关闭：仅未缩放态响应垂直拖拽
                    onVerticalDragStart: _zoomed ? null : _onDragStart,
                    onVerticalDragUpdate: _zoomed ? null : _onDragUpdate,
                    onVerticalDragEnd: _zoomed ? null : _onDragEnd,
                  ),
                ),
              ),
            ),
          ),
          // 右上角关闭按钮：半透明黑圆底 —— 白图上也看得清（纯白图标浮在白图上看不见）
          // 2026-11-07：下滑拖拽时浮层随进度渐隐
          SafeArea(
            child: Opacity(
              opacity: 1 - dim,
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    color: Colors.black45,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop(),
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child:
                            Icon(Icons.close, size: 22, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 页码指示（多图时）：顶部居中小胶囊
          if (multiple)
            SafeArea(
              child: Opacity(
                opacity: 1 - dim,
                child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      '${_index + 1} / ${_list.length}',
                      style: const TextStyle(fontSize: 13, color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 底部居中「保存到相册」半透明胶囊按钮（微信式）
          SafeArea(
            child: Opacity(
              opacity: 1 - dim,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Material(
                    color: Colors.white.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(22),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: _saving ? null : _save,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_saving)
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            else
                              const Icon(Icons.save_alt,
                                  size: 18, color: Colors.white),
                            const SizedBox(width: 6),
                            Text(t('momentsSaveToAlbum'),
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.white)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单页可缩放大图：1x 时把横滑让给 PageView 翻页；捏合放大后 panEnabled 打开
/// （可平移看细节），缩放回到 1x 自动复位并把横滑交还翻页。
class _ZoomableImage extends StatefulWidget {
  final String url;
  final ValueChanged<bool> onZoom;
  /// 长按图片弹功能菜单（2026-10-09：原为长按直接保存，改为弹菜单）
  final VoidCallback onLongPress;

  /// 2026-11-07 下滑关闭：未缩放（1x）时响应垂直拖拽（传 null 即不注册，
  /// 缩放态由父层置 null，双指缩放/平移手势不受影响）
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;

  const _ZoomableImage(
      {required this.url,
      required this.onZoom,
      required this.onLongPress,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final _ctrl = TransformationController();
  bool _zoomed = false;

  /// 加载失败标记 + 重试代次（2026-09-26）：磁盘缓存组件失败不缓存，
  /// 点一下 bump 代次换 key 重建即可重发下载；成功后磁盘命中秒开
  bool _failed = false;
  int _attempt = 0;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setZoom(bool v) {
    if (_zoomed == v) return;
    _zoomed = v;
    widget.onZoom(v);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      transformationController: _ctrl,
      minScale: 1,
      maxScale: 4,
      panEnabled: _zoomed, // 1x 时禁平移：横滑交给 PageView 翻页
      clipBehavior: Clip.none,
      onInteractionStart: (d) {
        // 双指按下立即进入缩放态（ScaleStartDetails 无 scale，捏合量在 update 里）
        if (!_zoomed && d.pointerCount > 1) _setZoom(true);
      },
      onInteractionUpdate: (d) {
        if (!_zoomed && d.scale != 1.0) _setZoom(true);
      },
      onInteractionEnd: (_) {
        if (_zoomed && _ctrl.value.getMaxScaleOnAxis() <= 1.01) {
          _ctrl.value = Matrix4.identity();
          _setZoom(false); // 缩放回到 1x → 复位并交还翻页手势
        }
      },
      child: Center(
        child: GestureDetector(
          // 长按大图 = 弹功能菜单（保存/识别二维码/发送给朋友/定位/收藏）
          // 加载失败时点一下重试
          // 2026-11-07：未缩放态响应垂直拖拽 → 下滑关闭（父层置 null 则不参与手势竞技）
          onVerticalDragStart: widget.onVerticalDragStart,
          onVerticalDragUpdate: widget.onVerticalDragUpdate,
          onVerticalDragEnd: widget.onVerticalDragEnd,
          onLongPress: widget.onLongPress,
          onTap: () {
            if (!_failed) return;
            setState(() {
              _failed = false;
              _attempt++;
            });
          },
          child: Hero(
            tag: 'hero-chat-img-${widget.url}',
            // 2026-09-26：Image.network → CachedNetworkImage（磁盘缓存：
            // 打开过一次的图冷启动/翻页秒开；失败可点击重试，不再黑屏干等）
            child: CachedNetworkImage(
              key: ValueKey('viewer-${widget.url}#$_attempt'),
              imageUrl: widget.url,
              fit: BoxFit.contain,
              placeholder: (_, __) => const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              ),
              errorWidget: (_, __, ___) {
                // builder 内只记标记（不触发重建），重试由点击处理
                _failed = true;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.broken_image_outlined,
                        size: 56, color: Colors.white54),
                    const SizedBox(height: 8),
                    Text('图片加载失败，点击重试',
                        style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.7))),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// 图片长按菜单项（2026-10-09）。
/// [id] 为动作标识，[labelKey] 为词条 key。
class _ImgAction {
  final String id;
  final IconData icon;
  final String labelKey;
  const _ImgAction(this.id, this.icon, this.labelKey);
}
