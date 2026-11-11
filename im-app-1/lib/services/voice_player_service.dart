import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'call_service.dart';

/// 全局语音播放状态，气泡据此高亮进度条 / 切换播放-暂停图标。
class VoicePlaybackState {
  final String? msgId; // 正在播放的消息 id（null = 空闲）
  final int positionMs;
  final int durationMs;
  final bool playing;

  /// 2026-11-11 修复「语音条点好几次才出声」：区分「已点击、正在下载/起播」
  /// 与「真的在出声」。此前点击瞬间就把 playing 置 true，用户听不到声音再点
  /// 一次时正好命中 toggle 的「同一条正在播 → 停止」分支，把第一次播放取消掉。
  final bool loading;

  const VoicePlaybackState({
    this.msgId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
    this.loading = false,
  });
}

/// 语音播放服务（单例）：同一时刻只播一条；点击正在播放的同一条则停止。
///
/// 2026-09-19 播放引擎从 flutter_sound 换成 audioplayers（iOS 语音修复）。
/// 原实现的两个 iOS 专属问题：
/// 1. **没声音**：flutter_sound 9.x 的 Dart 层没有任何音频会话控制，其原生
///    核心把会话固定在 PlayAndRecord（为录音设计）——iOS 上该类别默认走
///    **听筒**出声，录完/通话后再点播放，声音进了听筒，扬声器听不到；
///    Android 的 MediaPlayer 没有这种路由模型，所以安卓正常。
/// 2. **没动画**：其 startPlayer 对远程 URL 靠扩展名推断编解码，失败直接
///    抛异常被 toggle 的 catch 吃掉复位，气泡闪一下就回待播态，感知「点了没反应」。
/// 3. **首播延迟 7~8 秒**（2026-09-19 实测第二阶段）：远程 URL 交给 AVPlayer
///    流式播放，受服务器 Range/缓冲行为影响起播极慢——语音文件只有几十 KB，
///    改为**先下载到临时文件再本地播放**（秒起），并按 URL 缓存（重播瞬时）、
///    切换/停止时取消在途下载。
///
/// audioplayers 的解法：
/// - 每次播放前显式把音频会话复位成「媒体外放」（iOS playback；Android
///   normal+media，复位通话类残留的听筒路由，2026-11-13 修复扩音才有声）；
/// - 原生端下载后播本地文件（AVAudioPlayer 路径），起播零等待；
/// - H5 不下载，直接 URL 播（HTML5 Audio 自身处理，webm/opus 也能放）；
/// - 播放异常照样复位，但路径收敛且可预期。
class VoicePlayerService {
  VoicePlayerService._();
  static final instance = VoicePlayerService._();

  final AudioPlayer _player = AudioPlayer();
  final Dio _dl = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(seconds: 20),
  ));
  final Map<String, String> _fileCache = {}; // url → 本地缓存路径
  /// 2026-11-11 预下载：同一 url 的在途下载共享同一个 Future——预取与点播
  /// 复用同一次下载，用户点的时候不会因为"预取还没下完"又下一遍。
  final Map<String, Future<String>> _inflight = {};
  /// 已确认过文件还在的 url（避免每次 build 都做一次文件系统 exists 判断）
  final Set<String> _verified = {};
  /// 预取队列 + 并发上限（滚动长列表时不会几十条同时下载抢带宽）
  final List<String> _prefetchQueue = [];
  int _prefetchActive = 0;
  static const int _prefetchConcurrency = 3;
  /// 预取失败的 url → 失败时间（30s 内不重试，避免反复打网络）
  final Map<String, DateTime> _prefetchFailed = {};
  int _seq = 0; // 操作代序：下载回来时用户可能已经切到别条/停止
  String? _curMsgId;
  /// 2026-11-11：正在下载/起播中的消息 id（与 _curMsgId 分开：它表示「已出声」）
  String? _loadingMsgId;
  DateTime _loadingStart = DateTime.fromMillisecondsSinceEpoch(0);
  /// 2026-11-11：音频会话是否已复位成「媒体外放」，避免每次播放都做一次
  /// 原生 setAudioContext（iOS 切 category 有几十~几百毫秒延迟，是「点了要等一下
  /// 才响」的一部分）。通话中会被重置，见 _applyPlaybackContext。
  bool _ctxIsMedia = false;
  int _durationMs = 0;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<void>? _doneSub;
  bool _streamsBound = false;

  /// 当前播放状态（气泡订阅）。
  final ValueNotifier<VoicePlaybackState> state =
      ValueNotifier(const VoicePlaybackState());

  /// 进度/完成流是广播流，生命周期内只绑一次。
  void _bindStreams() {
    if (_streamsBound) return;
    _streamsBound = true;
    _posSub = _player.onPositionChanged.listen(_onPosition);
    _doneSub = _player.onPlayerComplete.listen((_) => _reset());
  }

  void _onPosition(Duration d) {
    if (_curMsgId == null) return;
    state.value = VoicePlaybackState(
      msgId: _curMsgId,
      playing: true,
      durationMs: _durationMs,
      positionMs: d.inMilliseconds,
    );
  }

  /// 点击气泡：同一 msgId 真的在出声 → 停止；正在下载/起播 → 忽略（不取消）；
  /// 播着别的条 → 切到该条从头播。
  /// [durationMs] 传消息自带的时长（波形进度条用，比播放器探测更快更稳）。
  Future<void> toggle(String url, String msgId, {int durationMs = 0}) async {
    _bindStreams();
    // 2026-11-11 修复「语音条要点好几次才有声音」：
    // 旧实现点击瞬间就 state.playing=true（此时还在下载、没有声音），用户以为
    // 没反应再点一次，正好命中「同一条正在播 → 停止」→ 第一次播放被取消，
    // 越点越没声。现在要求「已出声（非 loading）」才算在播，加载中的重复
    // 点击直接忽略，让第一次的下载/起播走完。
    if (state.value.playing && !state.value.loading && _curMsgId == msgId) {
      await _stop();
      return;
    }
    if (_loadingMsgId == msgId) {
      // 加载超过 10s 仍未起播（服务器/网络卡住）：放行本次点击重新开始，
      // 否则用户会一直停在转圈上，怎么点都没反应。
      if (DateTime.now().difference(_loadingStart).inSeconds < 10) return;
    }
    // 只有确实有别的条在播/在加载时才 stop：空闲点击不再白做一次原生 stop，
    // 少一次跨平台调用就少一段起播前的固定延迟。
    if (_curMsgId != null || _loadingMsgId != null) await _stop();
    // 点击优先：把该条从预取队列里提出来，由本次点击直接发起/复用下载
    _prefetchQueue.remove(url);
    final seq = ++_seq;
    _loadingMsgId = msgId;
    _loadingStart = DateTime.now();
    _durationMs = durationMs;
    // 立刻给 UI 一个「已受理」的反馈（loading 态，气泡显示转圈），但不算在播。
    state.value = VoicePlaybackState(
        msgId: msgId, playing: true, loading: true, durationMs: durationMs);
    try {
      Source source = UrlSource(url);
      if (!kIsWeb) {
        // 原生端：先下载再播本地文件。远程 URL 直接给 AVPlayer 起播要
        // 缓冲 7~8 秒（实测），语音只有几十 KB，下载秒级完成。
        // 2026-11-11：气泡渲染时已通过 prefetch() 预下载，这里绝大多数情况
        // 直接命中本地缓存（同步返回），点击即出声。
        final path = await _download(url);
        if (seq != _seq) return; // 下载期间用户已切走/停止：丢弃本次结果
        source = DeviceFileSource(path);
      }
      // 2026-11-13 修复「语音消息只有打开扬声器才有声音」：
      // 会话设置挪到**紧贴 play 之前**（下载耗时数秒，期间通话挂断/录音停止
      // 等事件可能把会话切回通话类），且两个平台都显式设置（见
      // _applyPlaybackContext 注释）。下载失败/切走的路径不再白白改会话。
      await _applyPlaybackContext();
      if (seq != _seq) return;
      _curMsgId = msgId;
      _loadingMsgId = null;
      state.value = VoicePlaybackState(
          msgId: msgId, playing: true, durationMs: durationMs);
      await _player.play(source);
    } catch (_) {
      // 下载失败 / 拉流失败 / 解码不支持（如 H5 录的 webm 在 iOS 原生端）：
      // 复位，气泡回到待播态。用户切走导致的取消不计（状态已被 stop 复位）。
      if (seq == _seq) _reset();
    }
  }

  /// 播放前显式设置音频会话（2026-11-13 修复「语音消息只有打开扬声器才有声音」）。
  ///
  /// 根因：通话类引擎（TRTC/WebRTC）会把音频会话/全局模式置成「通话」状态
  /// （iOS：PlayAndRecord 输出走**听筒**；Android：audioMode=IN_COMMUNICATION
  /// 媒体流被路由进听筒、音量极低），挂断后并不总是立即复原——此时播放
  /// 语音消息声音进听筒，听感就是「默认没声音，开扩音才有」。
  ///
  /// 解法：播放前把会话显式复位成「媒体外放」——
  /// - iOS：category=playback（扬声器出声）；
  /// - Android：audioMode=normal + usage=media（复位残留的通话模式，
  ///   STREAM_MUSIC 回到正常外放路由）。
  ///
  /// 通话**进行中**跳过本设置：通话的音频会话优先（TRTC playAndRecord），
  /// 此时改会话会破坏通话本身的收音/路由；通话场景的语音消息播放沿用
  /// 通话会话（听筒/扬声器随通话页开关），退出通话后恢复正常外放。
  Future<void> _applyPlaybackContext() async {
    // 通话中：先记为「会话已被通话占用」，本次不改。
    if (CallService.instance.state.value != null) {
      _ctxIsMedia = false;
      return;
    }
    // 2026-11-11：已经复位成媒体外放就跳过——每次播放都 setAudioContext 会
    // 多一次原生调用（iOS 切 category 有几十~几百毫秒），表现为「点了要等
    // 一下才响」。通话前后会话可能被改成通话类，所以只在通话标志出现时失效。
    if (_ctxIsMedia) return;
    // AudioContextIOS / AudioContext 构造器均非常量构造（audioplayers 6.x），
    // 仅 AudioContextAndroid 可 const
    await _player.setAudioContext(AudioContext(
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {},
      ),
      android: const AudioContextAndroid(
        isSpeakerphoneOn: false,
        audioMode: AndroidAudioMode.normal,
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.gain,
      ),
    ));
    _ctxIsMedia = true;
  }

  /// 2026-11-11：把语音提前下到本地缓存——气泡一渲染就调它，用户真去点的
  /// 时候文件通常已经在本地，点击即出声（不再"点了才开始下载"）。
  /// 内部去重 + 并发限流（最多 3 条同时下），失败 30 秒内不重试。
  void prefetch(String url) {
    if (url.isEmpty || kIsWeb) return;
    if (_isCached(url)) return;
    if (_inflight.containsKey(url)) return;
    final failedAt = _prefetchFailed[url];
    if (failedAt != null && DateTime.now().difference(failedAt).inSeconds < 30) {
      return;
    }
    if (_prefetchQueue.contains(url)) return;
    _prefetchQueue.add(url);
    _pumpPrefetch();
  }

  void _pumpPrefetch() {
    while (_prefetchActive < _prefetchConcurrency && _prefetchQueue.isNotEmpty) {
      final url = _prefetchQueue.removeAt(0);
      if (_inflight.containsKey(url)) continue;
      _prefetchActive++;
      unawaited(_runPrefetch(url));
    }
  }

  Future<void> _runPrefetch(String url) async {
    try {
      await _download(url);
    } catch (_) {
      // 失败只记时间，不冒泡、不打断聊天
      _prefetchFailed[url] = DateTime.now();
    } finally {
      _prefetchActive--;
      _pumpPrefetch();
    }
  }

  /// 本地是否已有可用副本（文件被系统清理时自动失效并重新下载）。
  bool _isCached(String url) {
    final path = _fileCache[url];
    if (path == null) return false;
    if (_verified.contains(url)) return true;
    if (File(path).existsSync()) {
      _verified.add(url);
      return true;
    }
    _fileCache.remove(url);
    return false;
  }

  /// 下载语音到临时文件（按 URL 缓存，命中且文件还在直接复用）。
  /// 2026-11-11：同一 url 的在途下载共享 Future——预取与点播复用同一次下载。
  Future<String> _download(String url) async {
    if (_isCached(url)) return _fileCache[url]!;
    final running = _inflight[url];
    if (running != null) return running;
    final f = _doDownload(url);
    _inflight[url] = f;
    try {
      return await f;
    } finally {
      if (identical(_inflight[url], f)) _inflight.remove(url);
    }
  }

  Future<String> _doDownload(String url) async {
    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().microsecondsSinceEpoch}${_extOf(url)}';
    final r = await _dl.download(url, path);
    if (r.statusCode == 200) {
      _fileCache[url] = path;
      _verified.add(url);
      return path;
    }
    throw Exception('voice download http ${r.statusCode}');
  }

  /// 从 URL 推断文件扩展名（iOS AVAudioPlayer 按扩展名识别格式；
  /// MinIO 带签名参数时先剥掉 query 再取）。
  static String _extOf(String url) {
    final clean = url.split('?').first.toLowerCase();
    final dot = clean.lastIndexOf('.');
    if (dot < 0) return '.m4a';
    final e = clean.substring(dot);
    return RegExp(r'^\.[a-z0-9]{2,5}$').hasMatch(e) ? e : '.m4a';
  }

  Future<void> _stop() async {
    // 2026-11-11：不再取消在途下载——下完直接进缓存，下次点击秒播；
    // 本次播放是否作废由 toggle 里的 seq 代序判断（下载回来发现已切走就丢弃）。
    try {
      await _player.stop();
    } catch (_) {}
    _reset();
  }

  void _reset() {
    _curMsgId = null;
    _loadingMsgId = null;
    _durationMs = 0;
    state.value = const VoicePlaybackState();
  }

  Future<void> dispose() async {
    await _posSub?.cancel();
    await _doneSub?.cancel();
    _posSub = null;
    _doneSub = null;
    _streamsBound = false;
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
