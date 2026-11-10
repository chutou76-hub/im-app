import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'call_media.dart';
import 'sound_service.dart'; // 2026-11-13 修复：浮窗自动进房补停回铃/接通音
import 'user_cache.dart';
import 'ws_service.dart';
import '../utils/call_debug_log.dart';
import '../utils/call_permissions.dart';

/// 通话阶段
enum CallPhase { idle, outgoing, incoming, connected }

/// 通话信令动作（承载在 type=7 消息的 content JSON 里）
class CallAction {
  static const invite = 'invite';
  static const accept = 'accept';
  static const reject = 'reject';
  static const hangup = 'hangup';
  static const cancel = 'cancel'; // 主叫在对方接听前挂断
  // ---- 群通话 / WebRTC 扩展（服务端纯透传）----
  static const join = 'join'; // 接听方媒体就绪，广播入房（WebRTC 触发 offer）
  static const leave = 'leave'; // 群通话中某人退出（通话对其他人继续）
  static const sdp = 'sdp'; // WebRTC offer/answer（{to, kind, sdp}）
  static const ice = 'ice'; // WebRTC ICE 候选（{to, candidate}）
}

/// 群通话成员（宫格 UI 展示）
class CallParticipant {
  final String id;
  final String name;
  final String avatar;
  const CallParticipant({required this.id, this.name = '', this.avatar = ''});

  @override
  bool operator ==(Object other) => other is CallParticipant && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// 通话引擎配置（/api/v1/trtc/config 归一化结果）
class CallConfig {
  final String engine; // trtc | webrtc | livekit
  final bool trtcEnabled; // engine=trtc 时是否已配置 appId
  final Map<String, dynamic> trtcSig; // /trtc/usersig 响应（appId/userId/userSig）
  final List<Map<String, dynamic>> iceServers; // WebRTC STUN/TURN
  final String livekitUrl; // LiveKit SFU 房间地址（engine=livekit 时有效）
  const CallConfig({
    required this.engine,
    required this.trtcEnabled,
    this.trtcSig = const {},
    this.iceServers = const [],
    this.livekitUrl = '',
  });

  bool get trtcUsable => engine == 'trtc' && trtcEnabled;
  bool get webrtcUsable => engine == 'webrtc' && iceServers.isNotEmpty;
  // LiveKit 走 SFU：无需 ICE 配置，有 url 即可用（token 由 /livekit/token 按通话签发）
  bool get livekitUsable => engine == 'livekit' && livekitUrl.isNotEmpty;
}

/// 全局通话状态（UI 通过 ValueNotifier 监听）
class CallState {
  final String convId;
  final String callType; // voice / video
  final String peerName;
  final String peerAvatar;
  final CallPhase phase;
  final bool isCaller;
  final bool isGroup; // 群组通话
  final String engine; // trtc | webrtc（invite 协商结果）
  final String callerName; // 群通话：发起人昵称（来电页副标题）

  const CallState({
    required this.convId,
    required this.callType,
    required this.peerName,
    required this.peerAvatar,
    required this.phase,
    required this.isCaller,
    this.isGroup = false,
    this.engine = 'trtc',
    this.callerName = '',
  });

  CallState copyWith({CallPhase? phase}) => CallState(
        convId: convId,
        callType: callType,
        peerName: peerName,
        peerAvatar: peerAvatar,
        phase: phase ?? this.phase,
        isCaller: isCaller,
        isGroup: isGroup,
        engine: engine,
        callerName: callerName,
      );
}

/// 一次性通话事件（供通话页弹提示 / 关闭页面）
class CallEvent {
  final String action; // accept / reject / hangup / cancel / timeout
  final String convId;
  final int duration;
  const CallEvent(this.action, this.convId, {this.duration = 0});
}

/// 通话信令服务（全局单例）
///
/// 职责：
/// 1. 主叫：发 invite → 等 accept（超时 45s 自动 cancel）
/// 2. 被叫：收 invite → 置 incoming（UI 弹来电页）→ accept/reject
/// 3. 任一方挂断：发 hangup（带时长），对端收到后关闭
/// 4. 群组通话：accept 后媒体就绪广播 join；退出发 leave（别人不挂）；参与人列表实时更新
/// 5. WebRTC 媒体信令（sdp/ice）：页面挂 [mediaSignalHandler] 后逐条转发
///
/// 信令全部走 type=7 消息，content 为 JSON：{action, callType, roomId, ...}
class CallService {
  CallService._();
  static final CallService instance = CallService._();

  final ValueNotifier<CallState?> state = ValueNotifier(null);

  /// 群通话参与人（含自己；UI 宫格监听）
  final ValueNotifier<List<CallParticipant>> participants =
      ValueNotifier(const []);

  /// 当前引擎配置（发起/接听时 ensureConfig 填充；通话页据此创建 CallMedia）
  CallConfig? config;

  // ================= 2026-11-13 通话浮窗需求：媒体生命周期上移 =================
  // 原方案：每个通话页在 State 里 createCallMedia + dispose 里 leave()——
  // 一 pop 路由媒体就挂断，通话无法收起为悬浮窗。现改为 CallService 持有
  // 媒体引擎，页面只负责取 media 渲染/操作；真正挂断（_reset）时才 leave()。

  /// 当前通话的媒体引擎（ensureMedia 创建；_reset 时 leave 并置空）
  CallMedia? _media;

  /// 媒体是否已进房（避免恢复全屏页时重复 join）
  bool _mediaJoined = false;

  /// 通话是否已收起为应用内悬浮窗（true 时全屏通话页已 pop，媒体仍在）
  final ValueNotifier<bool> minimized = ValueNotifier(false);

  /// 通话计时（秒）：接通后由服务层每秒 +1，浮窗与通话页共用同一数据源
  final ValueNotifier<int> callSeconds = ValueNotifier(0);

  /// 1:1 视频通话的远端用户 ID（null=对方画面未就绪；页面据此渲染远端流）
  final ValueNotifier<String?> remotePeerId = ValueNotifier(null);

  /// 计时器（接通时启动，_reset 停止）
  Timer? _secondsTimer;

  CallMedia? get media => _media;

  bool get mediaJoined => _mediaJoined;

  /// 通话页挂载的媒体信令处理器（sdp/ice/join/leave 转发进媒体引擎）。
  ///
  /// handler 尚未挂载时到达的信令先入 _pendingMediaSigs 队列，挂载后重放。
  /// 2026-09-17 视频通话「只看到自己画面」根因：被叫 accept 后立即广播 join，
  /// 而主叫还在拉配置/getUserMedia（视频初始化比语音慢数秒），join 早到被
  /// 静默丢弃 → 主叫永远不发 offer → 双方都收不到对方媒体。
  void Function(Map<String, dynamic> sig)? _mediaSignalHandler;

  /// handler 未就绪期间缓存的媒体信令（join/sdp/ice/leave）
  final List<Map<String, dynamic>> _pendingMediaSigs = [];

  void Function(Map<String, dynamic> sig)? get mediaSignalHandler =>
      _mediaSignalHandler;

  set mediaSignalHandler(void Function(Map<String, dynamic> sig)? fn) {
    _mediaSignalHandler = fn;
    if (fn == null) {
      // 通话结束/通话页销毁：清空缓存，防止跨通话重放旧信令
      _pendingMediaSigs.clear();
      return;
    }
    if (_pendingMediaSigs.isEmpty) return;
    final pending = List<Map<String, dynamic>>.of(_pendingMediaSigs);
    _pendingMediaSigs.clear();
    for (final sig in pending) {
      fn(sig);
    }
  }

  /// 媒体信令统一出口：handler 未就绪先缓存（上限 80 条，防异常堆积）
  void _dispatchMediaSignal(Map<String, dynamic> sig) {
    final h = _mediaSignalHandler;
    if (h != null) {
      h(sig);
      return;
    }
    final from = sig['from']?.toString() ??
        sig['userId']?.toString() ??
        sig['to']?.toString() ??
        '';
    if (from.isEmpty) return;
    if (_pendingMediaSigs.length < 80) _pendingMediaSigs.add(sig);
  }

  final _events = StreamController<CallEvent>.broadcast();
  Stream<CallEvent> get events => _events.stream;

  VoidCallback? _wsCancel;
  String _myId = '';
  Timer? _ringTimer;
  DateTime? _connectedAt;
  int _joinTs = 0; // 自己的 join 时间戳（glare 仲裁参考）
  /// 当前通话对应的 invite 记录 msgId（一通电话一条记录模型）：
  /// 主叫取自 invite 发送响应；被叫取自收到的 invite 消息帧。
  /// 结束信令（hangup/cancel/reject）携带它，服务端据此把 invite 记录
  /// 原地改写为最终状态（done/rejected/missed），而不是新增第二条记录。
  String _inviteMsgId = '';

  static const int _ringTimeoutSec = 45;

  /// 群通话 Mesh 人数上限（WebRTC 每对成员一条直连，人数多上行扛不住）
  static const int groupMaxMembers = 4;

  String get myId => _myId;

  /// 登录后调用：登记自己的 ID + 挂上全局 WS 监听
  Future<void> attach() async {
    await _ensureMyId();
    _wsCancel ??= GlobalWs.instance.onMessage(_onWsMessage);
    GlobalWs.instance.ensureConnected();
  }

  /// 自己的 ID（用于过滤自己信令的回显，避免把自己发的 invite 当成来电）
  Future<void> _ensureMyId() async {
    if (_myId.isNotEmpty) return;
    // 进程内缓存命中直接用（一次登录会话只拉一次 /user/profile）
    final cached = UserCache.myId;
    if (cached != null && cached.isNotEmpty) {
      _myId = cached;
      return;
    }
    try {
      final r = await ApiClient.instance.get('/api/v1/user/profile');
      final d = (r.data['data'] as Map<String, dynamic>?);
      UserCache.setMyProfile(d ?? {});
      _myId = d?['id']?.toString() ?? '';
    } catch (_) {}
  }

  void detach() {
    _wsCancel?.call();
    _wsCancel = null;
    _ringTimer?.cancel();
    _ringTimer = null;
    state.value = null;
  }

  /// 退出登录 / 切换账号：把通话相关的全局态彻底清干净。
  /// 不清的话 `_myId` 仍是上一个账号，接听来电时会把自己的信令回显误判成对方来电。
  Future<void> resetSession() async {
    _ringTimer?.cancel();
    _ringTimer = null;
    // 2026-11-10 对端掉线自动结束：清防抖计时器
    _peerGoneTimer?.cancel();
    _peerGoneTimer = null;
    _connectedAt = null;
    _joinTs = 0;
    // 2026-11-13 通话浮窗需求：媒体引擎归 CallService 持有，退号时一并销毁
    await _teardownMedia();
    state.value = null;
    participants.value = const [];
    mediaSignalHandler = null;
    detach();
    _myId = ''; // 换号登录必须清空，否则 attach 时会复用旧 ID
  }

  // ============================ 引擎配置 ============================

  /// 拉取通话引擎配置并归一化（一次通话只拉一次；TRTC 模式顺带签 usersig）
  /// 2026-11-01 修复「App 端进不了房」：userSig 是有时效的签名凭证，此前
  /// config（含 trtcSig）整体永久缓存 → App 开一阵后再通话用旧 sig 进房失败。
  /// 改为 TRTC 模式每次通话都重新签 usersig；webrtc/livekit 无时效凭证，照旧缓存。
  Future<CallConfig> ensureConfig() async {
    final cached = config;
    if (cached != null && cached.engine != 'trtc') {
      CallDebugLog.instance.log('ensureConfig cache hit engine=${cached.engine}');
      return cached;
    }
    var engine = 'trtc';
    var trtcEnabled = false;
    var iceServers = const <Map<String, dynamic>>[];
    var trtcSig = const <String, dynamic>{};
    var livekitUrl = '';
    try {
      final r = await ApiClient.instance.get('/api/v1/trtc/config');
      final c = (r.data['data'] as Map<String, dynamic>?) ?? {};
      final rawEngine = (c['engine']?.toString() ?? 'trtc');
      engine = ['webrtc', 'livekit'].contains(rawEngine) ? rawEngine : 'trtc';
      if (engine == 'trtc') {
        trtcEnabled = c['enabled'] == true;
        if (trtcEnabled) {
          try {
            final sig = await ApiClient.instance
                .get('/api/v1/trtc/usersig', query: {'room': ''});
            final d = (sig.data['data'] as Map<String, dynamic>?) ?? {};
            if (d['userSig'] != null) trtcSig = d;
          } catch (_) {}
          if (trtcSig.isEmpty) trtcEnabled = false;
        }
        // 2026-11-01 排障埋点：TRTC 配置/签名拉取结果
        CallDebugLog.instance.log(
            'ensureConfig engine=$engine trtcEnabled=$trtcEnabled sigKeys=${trtcSig.keys.toList()} sigLen=${(trtcSig['userSig']?.toString() ?? '').length} userId=${trtcSig['userId']} expire=${trtcSig['expire']}');
      } else if (engine == 'webrtc') {
        final w = c['webrtc'] as Map<String, dynamic>?;
        final raw = (w?['iceServers'] as List<dynamic>? ?? [])
            .whereType<Map>()
            .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
            .toList();
        iceServers = raw;
      } else if (engine == 'livekit') {
        final lk = c['livekit'] as Map<String, dynamic>?;
        livekitUrl = lk?['url']?.toString() ?? '';
      }
    } catch (e) {
      CallDebugLog.instance.log('ensureConfig FAIL: $e');
    }
    config = CallConfig(
      engine: engine,
      trtcEnabled: trtcEnabled,
      trtcSig: trtcSig,
      iceServers: iceServers,
      livekitUrl: livekitUrl,
    );
    return config!;
  }

  // ==================== 2026-11-13 通话浮窗需求：媒体持有 ====================

  /// 确保媒体引擎已创建（幂等：已存在直接返回 true）。
  /// 通话页不再自建 CallMedia——统一走这里，媒体生命周期随之归服务层，
  /// 通话页 pop（缩小为悬浮窗）不再触发 leave()。
  /// 返回 false = 引擎不可用（后台未配置 TRTC/WebRTC/LiveKit）。
  Future<bool> ensureMedia() async {
    if (_media != null) return true;
    final cfg = await ensureConfig();
    if (!(cfg.trtcUsable || cfg.webrtcUsable || cfg.livekitUsable)) {
      return false;
    }
    final m = createCallMedia(engine: cfg.engine, iceServers: cfg.iceServers);
    // 媒体外发信令（WebRTC sdp/ice）经 CallService type=7 透传（原页面接线迁移）
    m.onSignalOut = (sig) => sendMediaSignal(sig);
    // 1:1 视频远端用户变化 → 通知浮窗/通话页渲染远端流
    m.onRemoteJoined = (uid) => remotePeerId.value = uid;
    m.onRemoteLeft = (uid) {
      if (remotePeerId.value == uid) remotePeerId.value = null;
      // 2026-11-10 对端掉线自动结束：媒体层已感知对端离开（LiveKit 成员断连/
      // 房间断开、WebRTC ICE failed、TRTC 离房），单聊直接结束本端通话——
      // 对端杀进程不会发 hangup 信令，只能靠媒体层兜底（客户实测反馈）
      _onPeerMediaGone(uid);
    };
    // 媒体信令入口：handler 未就绪期间的缓存信令由 setter 自动重放
    mediaSignalHandler = (sig) => _media?.onSignalIn(sig);
    _media = m;
    return true;
  }

  /// 媒体进房（页面权限通过后调用；已进房时幂等返回成功）。
  /// 返回 null = 成功，否则错误文案（原 media.join 语义不变）。
  ///
  /// 2026-11-13 通话浮窗需求（QA 回归修复）：加进行中的 join 互斥锁——
  /// 振铃期自动进房（_autoJoinMedia）与浮窗恢复进房（页面 _enterRoom）
  /// 并发时，双方共享同一个 in-flight join，绝不双重 join 房间。
  ///
  /// 2026-11-13 修复「通话收起浮窗后没有声音」：`_media == null`（引擎还没
  /// 被创建）时不再**假成功返回 null**——旧返回值让 `_autoJoinMedia` 误以为
  /// 进房成功去广播 join，实际人不在房间里，对方声音永远收不到（浮窗里
  /// 也无声）。现在明确返回错误文案，由调用方展示/走恢复全屏重试。
  Future<String?>? _joinInFlight;

  Future<String?> joinMedia({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) {
    if (_mediaJoined || _media == null) {
      if (_mediaJoined) return Future.value(null); // 已进房：幂等成功
      // 2026-11-13 修复：引擎不存在不是「成功」，返回明确错误
      return Future.value('call engine unavailable');
    }
    final inflight = _joinInFlight;
    if (inflight != null) return inflight;
    final fut = _doJoinMedia(
      roomId: roomId,
      myId: myId,
      isVideo: isVideo,
      trtcSig: trtcSig,
    ).whenComplete(() => _joinInFlight = null);
    _joinInFlight = fut;
    return fut;
  }

  Future<String?> _doJoinMedia({
    required String roomId,
    required String myId,
    required bool isVideo,
    Map<String, dynamic>? trtcSig,
  }) async {
    final m = _media;
    // 2026-11-13 修复：引擎不存在返回明确错误（不再假成功，见 joinMedia 注释）
    if (m == null) return 'call engine unavailable';
    if (_mediaJoined) return null;
    final err = await m.join(
      roomId: roomId,
      myId: myId,
      isVideo: isVideo,
      trtcSig: trtcSig,
    );
    if (err == null) _mediaJoined = true;
    return err;
  }

  /// 2026-11-13 通话浮窗需求（QA 回归修复·必修）：振铃期收起浮窗后对方接听
  /// → 全屏通话页已 pop、events 订阅已取消，无人触发进房，对方会一直听不到
  /// 我们的声音（直到恢复全屏）。服务层在此兜底：若当前没有通话页在监听
  /// （页面 pop 后订阅取消 → _events.hasListener 为 false）且媒体未进房，
  /// 直接申请权限 + 进房 + 广播 join。全屏页在听时跳过（页面自己会进房）。
  /// 权限被拒时静默放弃——恢复全屏后页面会再次申请并进房。
  ///
  /// 2026-11-13 修复「通话收起浮窗后没有声音」：`_media == null` 时不再直接
  /// return——用户在通话页 `_prepare()` 完成之前（引擎尚未创建）就收起了浮窗
  /// 是常态，旧逻辑导致 accept 到达时这里空转、joinMedia 永远不被调用，
  /// 浮窗里全程无声。现在先 `ensureMedia()` 把引擎建起来再走统一进房链路
  /// （joinMedia 互斥锁保证与浮窗恢复页面的进房不会双重 join）。
  Future<void> _autoJoinMedia(CallState s) async {
    if (_events.hasListener) return; // 全屏通话页在听，由页面负责进房
    if (_mediaJoined) return;
    // 2026-11-13 修复：引擎可能尚未创建（收起时页面还没 ensureMedia）——
    // 这里补建；后台未配置引擎（返回 false）才放弃，恢复全屏后页面提示。
    if (_media == null) {
      final ok = await ensureMedia();
      if (!ok || _mediaJoined) return;
    }
    try {
      final granted = s.callType == 'video'
          ? (await CallPermissions.ensureForVideoSplit()).mic
          : await CallPermissions.ensureForVoice();
      if (!granted || _mediaJoined || state.value == null) return;
      final err = await joinMedia(
        roomId: s.convId,
        myId: _myId,
        isVideo: s.callType == 'video',
        trtcSig: config?.trtcSig,
      );
      if (err == null && state.value != null) {
        // 进房成功 → 广播 join（被叫/群成员触发对端 offer；单聊主叫无需广播）
        await notifyMediaJoined();
        // 2026-11-13 修复：浮窗态自动进房后补齐提示音——全屏页正常进房时
        // 会「停回铃 + 接通音」，浮窗兜底路径此前漏了（回铃音若还挂着会
        // 一直循环，与通话声音混在一起）。stopRingback 幂等，无副作用。
        SoundService.instance.stopRingback();
        SoundService.instance.playCallConnected();
      }
    } catch (_) {
      // 自动进房失败不阻断信令流程；恢复全屏时页面会重试
    }
  }

  /// 接通：启动全局计时（浮窗与通话页共用 callSeconds）
  void _startSecondsTimer() {
    _secondsTimer?.cancel();
    callSeconds.value = 0;
    _secondsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      callSeconds.value += 1;
    });
  }

  /// 结束：停止并清零计时
  void _stopSecondsTimer() {
    _secondsTimer?.cancel();
    _secondsTimer = null;
    callSeconds.value = 0;
  }

  /// 销毁媒体引擎（真正挂断/退号时调用；缩小浮窗绝不走这里）
  Future<void> _teardownMedia() async {
    _stopSecondsTimer();
    remotePeerId.value = null;
    minimized.value = false;
    _joinInFlight = null;
    final m = _media;
    _media = null;
    _mediaJoined = false;
    if (m != null) {
      try {
        await m.leave();
      } catch (_) {
        // leave 失败不阻断挂断流程
      }
    }
  }

  /// 收起为应用内悬浮窗：通话页 pop 前调用。
  /// 媒体在服务层不受 pop 影响，通话继续；浮窗由 CallFloatWindow 渲染。
  void minimize() {
    if (state.value != null) minimized.value = true;
  }

  // ============================ 主叫 ============================

  /// 发起单聊通话：发 invite 信令，进入 outgoing（等待对方接听）
  Future<void> startCall({
    required String convId,
    required String callType,
    required String peerName,
    String peerAvatar = '',
  }) async {
    config = await ensureConfig();
    // invite 信令必须带【主叫自己】的昵称/头像：
    // 2026-09-17 用户实测：旧实现把 peerName（= 会话对方 = 被叫的名字）当成
    // callerName 塞进信令，被叫 A 的来电页/接听页显示的是 A 自己。
    // 正确语义见 startGroupCall：从 UserCache 取主叫本人信息；
    // peerName/peerAvatar 参数只用于主叫自己的等待页展示。
    final me = UserCache.myProfileData;
    final myName = me?['nickname']?.toString() ?? '';
    final myAvatar = me?['avatar']?.toString() ?? '';
    final mid = await _sendSignal(
      convId: convId,
      action: CallAction.invite,
      callType: callType,
      callerName: myName,
      callerAvatar: myAvatar,
    );
    if (mid != null && mid.isNotEmpty) _inviteMsgId = mid;
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: peerName,
      peerAvatar: peerAvatar,
      phase: CallPhase.outgoing,
      isCaller: true,
      engine: config?.engine ?? 'trtc',
    );
    _startRingTimeout(convId);
  }

  /// 发起群组通话：邀请全群成员（room 即会话），信令带 group:true
  Future<void> startGroupCall({
    required String convId,
    required String callType,
    required String groupName,
    String groupAvatar = '',
  }) async {
    config = await ensureConfig();
    final me = UserCache.myProfileData;
    final myName = me?['nickname']?.toString() ?? '';
    final myAvatar = me?['avatar']?.toString() ?? '';
    final gMid = await _sendSignal(
      convId: convId,
      action: CallAction.invite,
      callType: callType,
      callerName: myName,
      callerAvatar: myAvatar,
      extras: {
        'group': true,
        'groupName': groupName,
        'groupAvatar': groupAvatar,
      },
    );
    if (gMid != null && gMid.isNotEmpty) _inviteMsgId = gMid;
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: groupName,
      peerAvatar: groupAvatar,
      phase: CallPhase.outgoing,
      isCaller: true,
      isGroup: true,
      engine: config?.engine ?? 'trtc',
      callerName: myName,
    );
    _setParticipants(
        [CallParticipant(id: _myId, name: myName, avatar: myAvatar)]);
    _startRingTimeout(convId);
  }

  void _startRingTimeout(String convId) {
    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: _ringTimeoutSec), () {
      final s = state.value;
      if (s != null && s.convId == convId && s.phase == CallPhase.outgoing) {
        _sendSignal(
            convId: convId,
            action: CallAction.cancel,
            callType: s.callType,
            extras: s.isGroup ? {'group': true} : null,
            // 单聊振铃超时 → cancel 需要服务端把 invite 记录改写为「通话未接通」；
            // 群通话 cancel 仍是纯信令。
            silent: s.isGroup);
        _reset();
        _emit(CallEvent(CallAction.cancel, convId));
      }
    });
  }

  // ============================ 被叫 ============================

  /// 接听：发 accept，进入 connected
  Future<void> accept() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    await _sendSignal(
      convId: s.convId,
      action: CallAction.accept,
      callType: s.callType,
      silent: true, // 纯信令：实时通知主叫即可，不落库成通话记录
    );
    _connectedAt = DateTime.now();
    _startSecondsTimer(); // 2026-11-13 通话浮窗需求：计时上移服务层
    // 2026-11-13 通话浮窗需求（QA 回归修复）：振铃期收起浮窗后接听 → 服务层兜底进房
    unawaited(_autoJoinMedia(s));
    state.value = s.copyWith(phase: CallPhase.connected);
    if (s.isGroup) {
      _addParticipant(CallParticipant(
        id: _myId,
        name: UserCache.myProfileData?['nickname']?.toString() ?? '',
        avatar: UserCache.myProfileData?['avatar']?.toString() ?? '',
      ));
    }
    _emit(CallEvent(CallAction.accept, s.convId));
  }

  /// 拒接：发 reject，回到 idle。
  /// 单聊 reject 非 silent：服务端把 invite 记录改写为「对方拒绝接听」。
  Future<void> reject() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    await _sendSignal(
      convId: s.convId,
      action: CallAction.reject,
      callType: s.callType,
      silent: s.isGroup,
    );
    _reset();
  }

  // ============================ 对端掉线自动结束（2026-11-10） ============================

  /// 对端媒体断开防抖计时器（LiveKit 房间断开会对每个成员各触发一次
  /// onRemoteLeft，需去重；800ms 内的多次触发合并为一次结束动作）
  Timer? _peerGoneTimer;

  /// 对端媒体连接断开（App 被杀/网络崩溃/离房）。单聊 → 自动结束本端通话；
  /// 群通话不打断（成员来去自由）；自己主动挂断触发的不处理（见防抖守卫）。
  void _onPeerMediaGone(String uid) {
    final s = state.value;
    if (s == null || s.isGroup) return;
    // 守卫：自己主动挂断/退出登录时 _teardownMedia 会先清 _media 再 leave()，
    // leave 引发的 RoomDisconnected → onRemoteLeft 走到这里直接忽略，
    // 避免对一通已结束的通话重复发信令
    if (_media == null) return;
    _peerGoneTimer ??= Timer(const Duration(milliseconds: 800), () {
      _peerGoneTimer = null;
      final s2 = state.value;
      if (s2 == null || s2.isGroup || _media == null) return;
      _autoEndPeerGone(s2);
    });
  }

  /// 对端掉线自动结束：best effort 上报 hangup（对端已死收不到，服务端
  /// 借此把 invite 记录改写为最终态，通话记录不留「进行中」），随后复位
  /// 状态机并广播 hangup 事件——全屏通话页/浮窗监听该事件统一收尾关闭。
  Future<void> _autoEndPeerGone(CallState s) async {
    final dur = _elapsedSec();
    _connectedAt = null;
    await _sendSignal(
      convId: s.convId,
      action: s.phase == CallPhase.connected
          ? CallAction.hangup
          : CallAction.cancel,
      callType: s.callType,
      duration: dur,
    );
    _reset();
    _emit(CallEvent(CallAction.hangup, s.convId, duration: dur));
  }

  // ============================ 通用 ============================

  /// 挂断：发 hangup（带通话时长），回到 idle
  /// 群通话：发 leave（带时长，可留通话记录），通话对其他成员继续
  Future<void> hangup() async {
    final s = state.value;
    if (s == null) return;
    _ringTimer?.cancel();
    // 先取时长再清 _connectedAt：_elapsedSec() 依赖它，先置 null 会恒得 00:00
    final dur = _elapsedSec();
    _connectedAt = null;
    final action = s.isGroup
        ? CallAction.leave
        : (s.phase == CallPhase.connected
            ? CallAction.hangup
            : CallAction.cancel);
    // 单聊 hangup/cancel **不 silent**：服务端把 invite 记录原地改写为最终态
    // （接通挂断 = 带时长的「语音通话 00:05」；未接取消 = 「通话未接通」），
    // 不再新增第二条通话记录。群 leave 是纯信令，只转发不落库。
    await _sendSignal(
      convId: s.convId,
      action: action,
      callType: s.callType,
      duration: dur,
      extras: s.isGroup ? {'group': true, 'userId': _myId} : null,
      silent: s.isGroup,
    );
    _reset();
  }

  int _elapsedSec() {
    final t = _connectedAt;
    if (t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }

  void _reset() {
    _ringTimer?.cancel();
    _ringTimer = null;
    // 2026-11-10 对端掉线自动结束：清防抖计时器
    _peerGoneTimer?.cancel();
    _peerGoneTimer = null;
    _connectedAt = null;
    state.value = null;
    participants.value = const [];
    mediaSignalHandler = null;
    _joinTs = 0;
    _inviteMsgId = '';
    // 2026-11-13 通话浮窗需求：真正结束通话才销毁媒体（含停计时/收浮窗标志）
    _teardownMedia();
  }

  void _emit(CallEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  // ============================ 媒体就绪 ============================

  /// 通话页媒体引擎 join 成功后调用：
  /// - 被叫/群成员广播 join（房间内已有成员向其发 WebRTC offer；TRTC 用于成员列表）
  /// - 单聊主叫不需要广播（主叫收到被叫 join 后主动 offer）
  Future<void> notifyMediaJoined() async {
    final s = state.value;
    if (s == null) return;
    _joinTs = DateTime.now().millisecondsSinceEpoch;
    if (s.isCaller && !s.isGroup) return;
    final me = UserCache.myProfileData;
    await _sendSignal(
      convId: s.convId,
      action: CallAction.join,
      callType: s.callType,
      silent: true,
      extras: {
        'group': true,
        'userId': _myId,
        'name': me?['nickname']?.toString() ?? '',
        'avatar': me?['avatar']?.toString() ?? '',
        'ts': _joinTs,
      },
    );
  }

  /// 转发 WebRTC 媒体信令（sdp/ice）到对端（type=7 透传，服务端零逻辑）
  Future<void> sendMediaSignal(Map<String, dynamic> sig) async {
    final s = state.value;
    if (s == null) return;
    await _sendSignal(
      convId: s.convId,
      action: sig['action']?.toString() ?? '',
      callType: s.callType,
      silent: true,
      extras: {...sig, 'group': true},
    );
  }

  // ============================ 参与人 ============================

  void _setParticipants(List<CallParticipant> list) {
    participants.value = List.unmodifiable(list);
  }

  void _addParticipant(CallParticipant p) {
    final list = [...participants.value];
    if (list.any((e) => e.id == p.id)) return;
    list.add(p);
    _setParticipants(list);
  }

  void _removeParticipant(String id) {
    _setParticipants(participants.value.where((e) => e.id != id).toList());
  }

  // ============================ 收信令 ============================

  Future<void> _onWsMessage(Map<String, dynamic> m) async {
    // 只处理通话信令 type=7
    final type = (m['type'] as num?)?.toInt();
    if (type != 7) return;

    // 自己 ID 未知时补拉一次，否则会把自己的信令回显当成对方来电
    await _ensureMyId();
    final senderId = m['senderId']?.toString() ?? '';
    // 自己的回显忽略
    if (senderId.isNotEmpty && senderId == _myId) return;

    final convId = m['conversationId']?.toString() ?? '';
    if (convId.isEmpty) return;

    Map<String, dynamic> sig = {};
    try {
      final raw = m['content'];
      sig = raw is String
          ? (jsonDecode(raw) as Map<String, dynamic>)
          : (raw as Map<String, dynamic>);
    } catch (_) {
      return;
    }
    sig['from'] = senderId; // 媒体信令需要知道来源成员
    final action = sig['action']?.toString() ?? CallAction.invite;
    final callType = sig['action'] == CallAction.invite
        ? (sig['callType']?.toString() ?? 'voice')
        : (state.value?.callType ?? sig['callType']?.toString() ?? 'voice');
    final isGroupSig = sig['group'] == true;

    switch (action) {
      case CallAction.invite:
        // 自己 invite 的 WS 回显/重复帧：msgId 与自己刚发出的 invite 相同。
        // 绝不能当成新来电走占线拒接（会把这通电话改写成「对方拒绝接听」，
        // 实测「一拨就提示被拒绝、对方还在响铃」就是它）。
        final mid = m['msgId']?.toString() ?? '';
        if (mid.isNotEmpty && mid == _inviteMsgId) return;
        if (mid.isNotEmpty) _inviteMsgId = mid;
        _onInvite(convId, sig, callType, isGroupSig);
        break;

      case CallAction.accept:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        if (s.isGroup) {
          // 群通话：成员接听只停主叫的等待态，不互相影响
          if (s.isCaller && s.phase != CallPhase.connected) {
            _ringTimer?.cancel();
            _connectedAt = DateTime.now();
            _startSecondsTimer(); // 2026-11-13 通话浮窗需求：计时上移服务层
            // 2026-11-13 通话浮窗需求（QA 回归修复）：振铃期收起浮窗 → 服务层兜底进房
            unawaited(_autoJoinMedia(s.copyWith(phase: CallPhase.connected)));
            state.value = s.copyWith(phase: CallPhase.connected);
            _emit(CallEvent(CallAction.accept, convId));
          }
          return;
        }
        _ringTimer?.cancel();
        _connectedAt = DateTime.now();
        _startSecondsTimer(); // 2026-11-13 通话浮窗需求：计时上移服务层
        // 2026-11-13 通话浮窗需求（QA 回归修复）：振铃期收起浮窗 → 服务层兜底进房
        unawaited(_autoJoinMedia(s.copyWith(phase: CallPhase.connected)));
        state.value = s.copyWith(phase: CallPhase.connected);
        _emit(CallEvent(CallAction.accept, convId));
        break;

      case CallAction.reject:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        if (s.isGroup) return; // 群通话：有人拒绝不影响其他人
        _reset();
        _emit(CallEvent(action, convId));
        break;

      case CallAction.hangup:
      case CallAction.cancel:
        final s = state.value;
        if (s == null || s.convId != convId) return;
        _reset();
        _emit(CallEvent(action, convId,
            duration: (sig['duration'] as num?)?.toInt() ?? 0));
        break;

      case CallAction.leave:
      // 群通话成员退出（单聊不会出现）
      case 'join':
        _onMemberSignal(convId, sig, action);
        break;

      case 'sdp':
      case 'ice':
        final s = state.value;
        if (s == null || s.convId != convId) return;
        // 群通话：先于我们入房的成员不会广播 join 给我们，只会直接发来 offer ——
        // 收到陌生来源的 sdp/ice 时补一个占位成员，宫格才能显示其画面
        if (s.isGroup) {
          final from = sig['from']?.toString() ?? '';
          if (from.isNotEmpty &&
              from != _myId &&
              !participants.value.any((e) => e.id == from)) {
            _addParticipant(CallParticipant(id: from));
          }
        }
        _dispatchMediaSignal(sig);
        break;
    }
  }

  void _onInvite(String convId, Map<String, dynamic> sig, String callType,
      bool isGroupSig) {
    // 已在通话中 → 直接回 busy（用 reject 语义）。
    // 非 silent：让服务端把这条新 invite 记录改写为「对方拒绝接听」。
    if (state.value != null) {
      final cur = state.value!;
      // 同一会话且我是主叫 → 这是自己 invite 的回显/重放（HTTP 响应未返回时
      // 回显先到，mid 比对兜不住），直接忽略，不发占线拒接。
      if (cur.isCaller && cur.convId == convId) return;
      _sendSignal(
          convId: convId,
          action: CallAction.reject,
          callType: callType,
          silent: false);
      return;
    }
    state.value = CallState(
      convId: convId,
      callType: callType,
      peerName: isGroupSig
          ? (sig['groupName']?.toString() ??
              sig['callerName']?.toString() ??
              '')
          : (sig['callerName']?.toString() ?? ''),
      peerAvatar: isGroupSig
          ? (sig['groupAvatar']?.toString() ?? '')
          : (sig['callerAvatar']?.toString() ?? ''),
      phase: CallPhase.incoming,
      isCaller: false,
      isGroup: isGroupSig,
      engine: sig['engine']?.toString() ?? 'trtc',
      callerName: sig['callerName']?.toString() ?? '',
    );
    if (isGroupSig) {
      _setParticipants([
        CallParticipant(
          id: sig['from']?.toString() ?? '',
          name: sig['callerName']?.toString() ?? '',
          avatar: sig['callerAvatar']?.toString() ?? '',
        )
      ]);
    }
  }

  /// 群通话的 join / leave：更新参与人 + 转发媒体引擎（WebRTC mesh 建连/拆除）
  /// 单聊也转发 join：主叫收到被叫 join 后才向其发 offer（TRTC 收到无影响）
  void _onMemberSignal(String convId, Map<String, dynamic> sig, String action) {
    final s = state.value;
    if (s == null || s.convId != convId) return;
    if (action == 'join') {
      final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
      if (uid.isEmpty || uid == _myId) return;
      if (s.isGroup) {
        _addParticipant(CallParticipant(
          id: uid,
          name: sig['name']?.toString() ?? '',
          avatar: sig['avatar']?.toString() ?? '',
        ));
      }
      _dispatchMediaSignal(sig);
    } else {
      if (!s.isGroup) return; // leave 只在群通话出现
      final uid = sig['userId']?.toString() ?? sig['from']?.toString() ?? '';
      if (uid.isEmpty) return;
      _removeParticipant(uid);
      _dispatchMediaSignal({'action': 'leave', 'userId': uid, 'from': uid});
      // 只剩自己（或没人）→ 通话结束
      final others = participants.value.where((e) => e.id != _myId).length;
      if (others == 0) {
        _reset();
        _emit(CallEvent(CallAction.hangup, convId));
      }
    }
  }

  // ============================ 发送信令 ============================

  /// 发送信令。返回服务端落库消息的 msgId（invite 落库时非空；纯信令为空），
  /// 主叫用它记住 invite 记录 ID，供结束信令回指。
  Future<String?> _sendSignal({
    required String convId,
    required String action,
    required String callType,
    int duration = 0,
    bool silent = false,
    String? callerName, // invite 信令主叫昵称覆盖（startCall 时 state 还没值）
    String? callerAvatar, // invite 信令主叫头像覆盖
    Map<String, dynamic>? extras, // 群通话/WebRTC 扩展字段
  }) async {
    try {
      final token = await ApiClient.instance.readToken();
      final r = await ApiClient.instance.dio.post(
        '/api/v1/message/send',
        data: {
          'conversationId': convId,
          'type': 7,
          'content': jsonEncode({
            'action': action,
            'callType': callType,
            'roomId': convId,
            'duration': duration,
            'callerName': callerName ?? state.value?.peerName ?? '',
            'callerAvatar': callerAvatar ?? state.value?.peerAvatar ?? '',
            'ts': DateTime.now().millisecondsSinceEpoch,
            // 结束信令回指 invite 记录（服务端据此原地改写，不新增第二条记录）
            if (_inviteMsgId.isNotEmpty) 'inviteMsgId': _inviteMsgId,
            if (extras != null) ...extras,
          }),
          // silent=true 的纯信令（accept/join/sdp/ice/群信令）：
          // 服务端只实时转发，不落库不写未读 —— 否则一次通话会把每条信令
          // 都存成「通话记录」气泡（线上实测：接通一次出现 5 条记录）。
          'silent': silent,
          'clientMsgId':
              'call-$action-${DateTime.now().millisecondsSinceEpoch}',
        },
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      final d = r.data;
      if (d is Map) {
        final data = d['data'];
        if (data is Map) {
          final mid = data['msgId']?.toString() ?? '';
          return mid.isEmpty ? null : mid;
        }
      }
    } catch (_) {
      // 信令发送失败不阻断 UI
    }
    return null;
  }
}
