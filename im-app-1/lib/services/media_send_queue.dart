import 'dart:async';

import 'api_client.dart';
import 'conversation_service.dart';
import 'local_store.dart';

/// 媒体消息（图片 type=2 / 视频 type=5 / 语音 type=4）发送阶段。
enum MediaSendStage {
  /// 正在上传文件本体（此时 content 里还没有可用的 URL）
  uploading,

  /// 文件已上传，正在把消息落库（sendRaw）
  sending,

  /// 服务端已确认（[MediaSendSnapshot.resp] 即服务端消息）
  sent,

  /// 上传或落库失败（[MediaSendSnapshot.retryable] 表示能否重试）
  failed,
}

/// 上传阶段的**业务**失败：`messageKey` 是一条 l10n key，
/// 由页面（UI 层）负责本地化，service 层不硬编码任何文案。
class MediaSendFailure implements Exception {
  /// l10n key（例如 `chatUploadAllFailed` / `chatFileNotSupported`）
  final String messageKey;

  const MediaSendFailure(this.messageKey);

  @override
  String toString() => 'MediaSendFailure($messageKey)';
}

/// 上传成功的产物：真正要落库的 content 与文件元数据。
class MediaUploadOutcome {
  /// 要发送的消息内容：
  ///   - 图片：`url1|url2|...`
  ///   - 视频/语音：JSON 字符串（含 url / thumb / duration …）
  final String content;

  /// 文件元数据（视频带 object/name/size/mimeType，语音为 null）
  final Map<String, dynamic>? file;

  /// 成功上传的数量（多图部分失败时用于 toast 统计）
  final int okCount;

  /// 上传失败被丢弃的数量
  final int failCount;

  const MediaUploadOutcome(
    this.content, {
    this.file,
    this.okCount = 1,
    this.failCount = 0,
  });
}

/// 一次媒体发送任务的只读快照。
///
/// 页面（State）只消费快照，不参与上传/发送本身，因此页面 dispose
/// 不会中断发送链路，也不会因为 setState 抛错而丢消息。
class MediaSendSnapshot {
  /// 会话 ID
  final String convId;

  /// 本地幂等 ID（气泡主键）
  final String clientMsgId;

  /// 消息类型（[MessageType.image] / [MessageType.video] / [MessageType.voice]）
  final int type;

  /// 当前阶段
  final MediaSendStage stage;

  /// 上传进度 0.0-1.0（多图按总字节聚合）
  final double progress;

  /// 当前 content（uploading 阶段为占位内容，sending 之后为最终内容）
  final String content;

  /// 当前文件元数据
  final Map<String, dynamic>? file;

  /// 失败原因（仅 failed 阶段非空）
  final Object? error;

  /// 服务端消息（仅 sent 阶段非空）
  final Map<String, dynamic>? resp;

  /// 是否能重试（本地文件仍可用 / 网络类瞬时失败）
  final bool retryable;

  /// 失败时是否已经过了上传阶段（true = 失败在落库，content 已是最终内容）
  final bool uploaded;

  /// 成功上传/发送的张数（图片部分失败统计用）
  final int okCount;

  /// 上传失败被丢弃的张数
  final int failCount;

  const MediaSendSnapshot({
    required this.convId,
    required this.clientMsgId,
    required this.type,
    required this.stage,
    this.progress = 0.0,
    this.content = '',
    this.file,
    this.error,
    this.resp,
    this.retryable = true,
    this.uploaded = false,
    this.okCount = 0,
    this.failCount = 0,
  });
}

/// 一次媒体发送任务的输入。
///
/// [upload] 由页面提供（图片可能多张、视频要抽封面、语音要拼 JSON），
/// 队列只负责「落盘 → 上传 → 落库 → 通知」，与 UI 完全解耦。
class MediaSendTask {
  /// 会话 ID
  final String convId;

  /// 本地幂等 ID
  final String clientMsgId;

  /// 消息类型
  final int type;

  /// 引用消息 ID（可选）
  final String? replyTo;

  /// 上传期间的占位 content（图片为空串；视频/语音为带空 url 的 JSON）
  final String placeholderContent;

  /// 上传期间的文件元数据（视频气泡需要 name/size/mimeType 才能画占位）
  final Map<String, dynamic>? placeholderFile;

  /// 本地待上传文件清单 `[{path, name, mimeType}]`：
  /// 持久化进发件箱，进程被杀后重进会话可据此重建任务续传。
  final List<Map<String, dynamic>> mediaFiles;

  /// 本任务包含的媒体数量（多图 > 1）
  final int totalCount;

  /// 真正执行上传的闭包；[onProgress] 报 0.0-1.0 聚合进度。
  final Future<MediaUploadOutcome> Function(void Function(double) onProgress)
      upload;

  const MediaSendTask({
    required this.convId,
    required this.clientMsgId,
    required this.type,
    required this.upload,
    this.replyTo,
    this.placeholderContent = '',
    this.placeholderFile,
    this.mediaFiles = const <Map<String, dynamic>>[],
    this.totalCount = 1,
  });
}

/// 媒体发送队列（**进程级单例**）。
///
/// 背景（线上 Bug）：「私聊发视频/图片，上传中返回首页再进会话，消息彻底消失」。
/// 旧实现的占位气泡只活在聊天页 State 的 `_msgs` 里，且：
///   1. 发件箱是**上传结束后**才登记 → 上传期间的十几秒里没有任何持久化记录；
///   2. 上传结束后的 `setState` 没有 `mounted` 守卫 → 页面已 dispose 时抛
///      `setState() called after dispose()`，异常直接打断后续 `_trackPending`
///      与 `sendRaw` → 服务端也没收到消息。
///
/// 现在把「上传 + 发送」从页面 State 里搬出来：
///   - 任务开始的第一件事就是把占位记录写进发件箱（stage=upload）；
///   - 页面只订阅快照画气泡，dispose 只是取消订阅，不影响任务继续跑；
///   - 上传完成 → 发件箱升级为最终 content（stage=send）→ sendRaw → 出箱。
class MediaSendQueue {
  MediaSendQueue._();

  /// 全局实例（发送链路不绑定任何页面生命周期）
  static final MediaSendQueue instance = MediaSendQueue._();

  /// 发件箱 `stage` 取值：上传中（content 里还没有 URL，**禁止**直接重发）
  static const String stageUpload = 'upload';

  /// 发件箱 `stage` 取值：已上传、待落库（content 已是最终 URL，可直接重发）
  static const String stageSend = 'send';

  /// 发件箱字段：本地待上传文件清单
  static const String kMediaFiles = 'mediaFiles';

  final ConversationService _svc = ConversationService();

  /// 同时执行的媒体任务上限。
  ///
  /// 相册不设张数上限，一次选 10 个视频会同时发起 10 路 `uploadXFile` +
  /// 10 次 `VideoThumbnail.thumbnailData` + 10 个 `VideoPlayerController.initialize()`，
  /// native 解码器并发初始化是已知崩点 → 超过上限的任务先**排队**
  /// （排队期间已有「uploading / progress=0」快照，气泡不会白屏等待）。
  static const int maxConcurrent = 3;

  /// 正在执行的任务（clientMsgId → 任务）；同一 ID 不会并发，避免重复上传。
  /// 注意：**排队中的任务也在本 Map 里**（isRunning=true），排队位置见 [_waiting]。
  final Map<String, MediaSendTask> _running = <String, MediaSendTask>{};

  /// 等待空闲并发位的任务（FIFO）
  final List<MediaSendTask> _waiting = <MediaSendTask>[];

  /// 当前占用并发位的任务数（只由 [_pump] 增加、[_run] 的 finally 减少）
  int _active = 0;

  /// 页面订阅者（聊天页 initState 注册、dispose 注销）
  final List<void Function(MediaSendSnapshot)> _listeners =
      <void Function(MediaSendSnapshot)>[];

  /// 进行中任务的最近一次快照（页面中途进入时用它恢复「正在上传」的气泡）
  final Map<String, MediaSendSnapshot> _last =
      <String, MediaSendSnapshot>{};

  /// 上传阶段兜底超时（5 分钟）。
  ///
  /// dio 的 sendTimeout 只覆盖网络段；native 侧偶发挂死（`VideoThumbnail.thumbnailData`
  /// 抽帧 / `VideoPlayerController.initialize` 读时长不返回）会让任务永远进不了
  /// finally → 并发位被永久占住，3 个之后整个队列停摆、后续媒体气泡永远停在 0%。
  /// 注意：`Future.timeout` **不会取消底层任务**（Dart 没有取消语义），底层可能
  /// 还在后台跑，但本任务一定会终结并释放并发位（迟到的进度回调会被
  /// [_emitProgress] 的 isRunning 判断丢掉）。
  static const Duration _uploadTimeout = Duration(minutes: 5);

  /// 该 clientMsgId 是否仍在发送中（含排队中；页面重进时判断「接着等」还是「重走上传」）
  bool isRunning(String clientMsgId) => _running.containsKey(clientMsgId);

  /// 进行中任务的最近快照；已结束 / 不存在返回 null
  MediaSendSnapshot? snapshotOf(String clientMsgId) => _last[clientMsgId];

  /// 订阅进度/结果（同一回调重复注册会被忽略）
  void addListener(void Function(MediaSendSnapshot) cb) {
    if (!_listeners.contains(cb)) _listeners.add(cb);
  }

  /// 取消订阅（页面 dispose 时必须调用，否则会向已销毁的 State 派发事件）
  void removeListener(void Function(MediaSendSnapshot) cb) {
    _listeners.remove(cb);
  }

  /// 启动一次媒体发送（幂等：同一 clientMsgId 正在跑/排队则忽略）。
  ///
  /// 同步返回，调用方（页面）不需要 await——上传/发送由队列继续负责。
  /// 若当前并发位已满，任务进入排队（仍会立刻发一张「uploading / 0」快照）。
  void start(MediaSendTask task) {
    if (task.clientMsgId.isEmpty) return;
    if (_running.containsKey(task.clientMsgId)) return;
    _running[task.clientMsgId] = task;
    // 先把记录落盘（**排队期间也算**）：此时还没开始传文件，但用户已经
    // 决定要发这条消息，杀进程后必须能恢复。
    unawaited(LocalStore.appendOutbox(
      task.convId,
      _outboxItem(task, stage: stageUpload),
      overwrite: true,
    ));
    _emit(MediaSendSnapshot(
      convId: task.convId,
      clientMsgId: task.clientMsgId,
      type: task.type,
      stage: MediaSendStage.uploading,
      progress: 0.0,
      content: task.placeholderContent,
      file: task.placeholderFile,
    ));
    _waiting.add(task);
    _pump();
  }

  /// 用空闲并发位启动排队任务（FIFO）。
  void _pump() {
    while (_active < maxConcurrent && _waiting.isNotEmpty) {
      final task = _waiting.removeAt(0);
      _active++;
      unawaited(_run(task));
    }
  }

  /// 执行「上传 → 升级发件箱 → 落库 → 出箱」，并保证**任何出口**都终结任务。
  ///
  /// 兜底约定：`_running.remove` / 并发位释放 / 终结快照派发三者都在 finally，
  /// 否则一次意外异常就会让任务永久留在 `_running`：气泡卡在「发送中」、
  /// 同一 clientMsgId 也再也 start 不了（杀进程才能恢复）。
  Future<void> _run(MediaSendTask task) async {
    final cmid = task.clientMsgId;
    // 终结快照：正常路径在 try 里赋值，finally 统一派发；未被赋值（异常/提前
    // return）时按「上传未完成的可重试失败」兜底。
    MediaSendSnapshot? terminal;
    var uploaded = false;
    MediaUploadOutcome? rawOutcome;
    try {
      // 1) 上传文件本体（发件箱记录已在 start() 里落好）
      try {
        // 兜底超时见 [_uploadTimeout]：native 挂死也必须终结任务、释放并发位
        rawOutcome = await task
            .upload((p) => _emitProgress(task, p))
            .timeout(_uploadTimeout);
        uploaded = true;
      } catch (e) {
        // 超时对用户来说就是「上传没成功」，换成可读文案（网络/文件都还在 → 可重试）
        final error =
            e is TimeoutException ? const MediaSendFailure('chatMediaUploadTimeout') : e;
        // 本地文件还在 → 保留发件箱记录，重进会话/点「!」可重试；
        // 文件已不可用（H5 刷新、缓存被清）→ 出箱，别留一条注定失败的记录。
        // 出箱在 emit 之前：此刻 isRunning 仍为 true，重进会话的页面只会订阅
        // 等待，不会抢先重起一次上传。
        final retryable = task.mediaFiles.isNotEmpty;
        if (!retryable) await LocalStore.removeOutbox(task.convId, cmid);
        terminal = MediaSendSnapshot(
          convId: task.convId,
          clientMsgId: cmid,
          type: task.type,
          stage: MediaSendStage.failed,
          progress: 1.0,
          content: task.placeholderContent,
          file: task.placeholderFile,
          error: error,
          retryable: retryable,
        );
        return;
      }

      // 2) 上传完成：发件箱升级为最终 content（stage=send 才允许「重发」，
      //    否则重进会话会拿着空 content 走 sendRaw 发出一条空媒体消息）
      final outcome = rawOutcome; // 上传失败路径已 return，此处必非空
      await LocalStore.appendOutbox(
        task.convId,
        _outboxItem(
          task,
          stage: stageSend,
          content: outcome.content,
          file: outcome.file,
        ),
        overwrite: true,
      );
      _emit(MediaSendSnapshot(
        convId: task.convId,
        clientMsgId: cmid,
        type: task.type,
        stage: MediaSendStage.sending,
        progress: 1.0,
        content: outcome.content,
        file: outcome.file,
        uploaded: true,
        okCount: outcome.okCount,
        failCount: outcome.failCount,
      ));

      // 3) 落库（服务端按 clientMsgId 幂等）
      try {
        final resp = await _svc.sendRaw(
          task.convId,
          task.type,
          outcome.content,
          clientMsgId: cmid,
          replyTo: task.replyTo,
          file: outcome.file,
        );
        await LocalStore.removeOutbox(task.convId, cmid);
        // 历史缓存写入失败不能让「已成功发送」变成失败（WS 回声还会补一次）
        try {
          ConversationService.historyCacheAppend(task.convId, resp);
        } catch (_) {}
        terminal = MediaSendSnapshot(
          convId: task.convId,
          clientMsgId: cmid,
          type: task.type,
          stage: MediaSendStage.sent,
          progress: 1.0,
          content: outcome.content,
          file: outcome.file,
          resp: resp,
          uploaded: true,
          okCount: outcome.okCount,
          failCount: outcome.failCount,
        );
      } catch (e) {
        // 瞬时故障保留在发件箱等下次进页重发；业务失败（禁言/非成员…）直接出箱
        final retryable = ApiClient.isTransient(e);
        if (!retryable) await LocalStore.removeOutbox(task.convId, cmid);
        terminal = MediaSendSnapshot(
          convId: task.convId,
          clientMsgId: cmid,
          type: task.type,
          stage: MediaSendStage.failed,
          progress: 1.0,
          content: outcome.content,
          file: outcome.file,
          error: e,
          retryable: retryable,
          uploaded: true, // 失败在落库阶段：气泡保留（与旧行为一致）
          okCount: outcome.okCount,
          failCount: outcome.failCount,
        );
      }
    } catch (e) {
      // 兜底：发件箱读写等未预期异常也必须终结任务，不能让气泡永久转圈。
      terminal = MediaSendSnapshot(
        convId: task.convId,
        clientMsgId: cmid,
        type: task.type,
        stage: MediaSendStage.failed,
        progress: 1.0,
        content: rawOutcome?.content ?? task.placeholderContent,
        file: rawOutcome?.file ?? task.placeholderFile,
        error: e,
        retryable: true, // 发件箱异常不代表文件没了：留给用户手动重试
        uploaded: uploaded,
      );
    } finally {
      // 唯一出口：释放并发位 → 移出运行表 → 派发终结快照 → 递补排队任务。
      // 顺序固定，且 _active 的递减一定与 _pump 的递增配对（异常路径同样覆盖）。
      _running.remove(cmid);
      assert(_active > 0, 'active 计数器失衡：递减多于递增（队列会停摆）');
      if (_active > 0) _active--;
      // _emit 是唯一可能意外抛错的地方：用 try/finally 保证 _pump 一定执行，
      // 否则一次派发异常就会让排队任务永远等不到并发位（队列停摆）。
      try {
        _emit(terminal ??
            MediaSendSnapshot(
              convId: task.convId,
              clientMsgId: cmid,
              type: task.type,
              stage: MediaSendStage.failed,
              progress: 1.0,
              content: task.placeholderContent,
              file: task.placeholderFile,
              retryable: true,
            ));
      } finally {
        _pump();
      }
    }
  }

  /// 构造发件箱记录（结构与旧版兼容：conversationId/clientMsgId/type/content/file）
  Map<String, dynamic> _outboxItem(
    MediaSendTask task, {
    required String stage,
    String? content,
    Map<String, dynamic>? file,
  }) {
    final meta = file ?? task.placeholderFile;
    return <String, dynamic>{
      'conversationId': task.convId,
      'clientMsgId': task.clientMsgId,
      'type': task.type,
      'content': content ?? task.placeholderContent,
      'stage': stage,
      if (task.replyTo != null && task.replyTo!.isNotEmpty)
        'replyTo': task.replyTo,
      if (meta != null) 'file': meta,
      if (task.mediaFiles.isNotEmpty) kMediaFiles: task.mediaFiles,
      'totalCount': task.totalCount,
    };
  }

  /// 派发进度（节流：跨 2% 或到达 100% 才推，避免每块字节都刷一帧）。
  ///
  /// 任务已终结（超时/失败/成功）后底层上传可能仍在跑并继续回调 —— 一律丢弃，
  /// 否则会把已经失败的气泡重新刷成「上传中」，或者给已出箱的任务复活快照。
  void _emitProgress(MediaSendTask task, double p) {
    if (!_running.containsKey(task.clientMsgId)) return;
    final raw = (p.isNaN || p.isInfinite) ? 0.0 : p;
    final next = raw.clamp(0.0, 1.0);
    final prev = _last[task.clientMsgId]?.progress ?? 0.0;
    if (next < 1 && (next - prev).abs() < 0.02) return;
    if ((next - prev).abs() < 0.001) return;
    _emit(MediaSendSnapshot(
      convId: task.convId,
      clientMsgId: task.clientMsgId,
      type: task.type,
      stage: MediaSendStage.uploading,
      progress: next,
      content: task.placeholderContent,
      file: task.placeholderFile,
    ));
  }

  /// 通知所有订阅者；单个订阅者异常绝不影响发送链路本身。
  void _emit(MediaSendSnapshot s) {
    if (s.stage == MediaSendStage.uploading ||
        s.stage == MediaSendStage.sending) {
      _last[s.clientMsgId] = s;
    } else {
      _last.remove(s.clientMsgId); // 终结态不再保留，防长期运行无限增长
    }
    for (final cb
        in List<void Function(MediaSendSnapshot)>.of(_listeners)) {
      try {
        cb(s);
      } catch (_) {
        // 订阅者（UI）自身异常吞掉：消息已经落盘/落库，不能因为 UI 出错回滚
      }
    }
  }
}
