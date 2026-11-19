import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../models/classroom_event.dart';
import '../models/submission_job.dart';
import '../models/ykt_problem.dart';
import 'auto_submit_store.dart';
import 'submission_coordinator.dart';
import 'ykt_api_client.dart';
import 'ykt_session_store.dart';
import 'ykt_socket.dart';

class BackgroundAutoSubmitService {
  static const notificationId = 1201;
  static const channelId = 'ykt_auto_submit';
  static final _service = FlutterBackgroundService();
  static const _notificationChannel = MethodChannel(
    'site.jiclub/notifications',
  );

  static Future<void> initialize() async {
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: backgroundAutoSubmitOnStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: channelId,
        initialNotificationTitle: '晴课堂自动提交守护中',
        initialNotificationContent: '正在监听老师发布的随堂题',
        foregroundServiceNotificationId: notificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: backgroundAutoSubmitOnStart,
        onBackground: onIosBackground,
      ),
    );
  }

  static Future<bool> start() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    return _service.startService();
  }

  static Future<void> stop() async {
    if (kIsWeb) return;
    if (await _service.isRunning()) {
      _service.invoke('stop');
    }
  }

  static Future<void> stopAndWait({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (kIsWeb) return;
    if (!await _service.isRunning()) return;
    _service.invoke('stop');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!await _service.isRunning()) return;
    }
  }

  static Future<bool> isRunning() async {
    if (kIsWeb) return false;
    return _service.isRunning();
  }

  static Future<bool> requestNotificationPermission() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }
    try {
      return await _notificationChannel.invokeMethod<bool>(
            'requestPermission',
          ) ??
          false;
    } on PlatformException {
      return false;
    }
  }
}

@pragma('vm:entry-point')
Future<bool> onIosBackground(ServiceInstance service) async {
  return false;
}

@pragma('vm:entry-point')
Future<void> backgroundAutoSubmitOnStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final store = AutoSubmitStore();
  final sessionStore = YktSessionStore();
  if (!await store.readEnabled()) {
    await service.stopSelf();
    return;
  }
  final session = await sessionStore.readSession();
  final context = await sessionStore.readBackgroundContext();
  if (session == null || context == null || !context.isValid) {
    await service.stopSelf();
    return;
  }
  final allowOvertime = await sessionStore.readAllowOvertime();

  var lease = await store.acquireOwner(
    owner: RuntimeOwner.background,
    lessonId: context.lessonId,
  );
  if (lease.owner != RuntimeOwner.background) {
    await Future<void>.delayed(const Duration(milliseconds: 450));
    lease = await store.acquireOwner(
      owner: RuntimeOwner.background,
      lessonId: context.lessonId,
    );
  }
  if (lease.owner != RuntimeOwner.background) {
    await store.appendLog('background owner denied by ${lease.owner.name}');
    await service.stopSelf();
    return;
  }

  final api = YktApiClient();
  YktSocket? socket;
  StreamSubscription<ClassroomEvent>? socketSubscription;
  Timer? reconnectTimer;
  Timer? timelineTimer;
  Timer? submissionTimer;
  Timer? leaseTimer;
  var closing = false;
  var eventQueue = Future<void>.value();
  late final SubmissionCoordinator coordinator;

  Future<void> updateNotification(String message) async {
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: '晴课堂自动提交守护中',
        content: message,
      );
    }
  }

  Future<void> shutdownOwner() async {
    if (closing) return;
    closing = true;
    reconnectTimer?.cancel();
    timelineTimer?.cancel();
    submissionTimer?.cancel();
    leaseTimer?.cancel();
    await socketSubscription?.cancel();
    await socket?.close(lessonId: context.lessonId);
    await store.releaseOwner(lease);
    api.dispose();
    await service.stopSelf();
  }

  Future<void> handleJobChanged(SubmissionJob job) async {
    await store.appendLog(
      'job ${job.problemId} -> ${job.state.name} '
      'code=${job.lastCode} ${job.lastMessage}',
    );
    switch (job.state) {
      case SubmissionJobState.scheduled:
        final remaining =
            job.scheduledAt - DateTime.now().millisecondsSinceEpoch;
        final seconds = remaining <= 0 ? 0 : (remaining / 1000).ceil();
        await updateNotification(
          seconds <= 0
              ? '已匹配预选答案，正在自动提交：${job.title}'
              : '已匹配预选答案，将在 $seconds 秒后自动提交：${job.title}',
        );
      case SubmissionJobState.succeeded:
        await updateNotification('已自动提交：${job.title}');
      case SubmissionJobState.alreadyAnswered:
        await updateNotification('该题已在其他客户端作答：${job.title}');
      case SubmissionJobState.authBlocked:
        await updateNotification('雨课堂登录已失效，自动提交已暂停');
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await shutdownOwner();
      case SubmissionJobState.unknownOutcome:
      case SubmissionJobState.retryableFailed:
      case SubmissionJobState.retryRequired:
        await updateNotification('自动提交暂未完成，正在确认结果');
      default:
        break;
    }
  }

  coordinator = SubmissionCoordinator(
    api: api,
    store: store,
    session: session,
    lessonId: context.lessonId,
    bearerToken: context.bearerToken,
    allowOvertime: allowOvertime,
    onJobChanged: handleJobChanged,
  );

  Future<void> inspectTimeline(List timeline) async {
    for (final item in timeline) {
      if (item is! Map) continue;
      final raw = Map<String, dynamic>.from(item);
      final nested = raw['problem'];
      final type = '${raw['type'] ?? raw['op'] ?? ''}'.toLowerCase();
      if (type != 'problem' &&
          type != 'embedded_problem' &&
          nested is! Map &&
          raw['prob'] == null &&
          raw['problemid'] == null &&
          raw['problemId'] == null) {
        continue;
      }
      final payload = nested is Map
          ? Map<String, dynamic>.from(nested)
          : Map<String, dynamic>.from(raw);
      for (final key in ['prob', 'problemid', 'problemId', 'id', 'dt']) {
        if (raw[key] != null) payload[key] = raw[key];
      }
      final problem = YktProblem.fromJson(
        payload,
        published: true,
        source: ProblemSource.timeline,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (problem.id.isEmpty) continue;
      final job = await coordinator.observePublish(problem, live: false);
      if (job?.state == SubmissionJobState.scheduled) {
        await store.appendLog('timeline promoted waiting job=${problem.id}');
      }
    }
  }

  Map<String, dynamic> eventProblemPayload(ClassroomEvent event) {
    final raw = event.problem ?? event.payload;
    final nested = event.payload['problem'];
    final payload = nested is Map
        ? Map<String, dynamic>.from(nested)
        : Map<String, dynamic>.from(raw);
    for (final key in [
      'dt',
      'time',
      'limit',
      'timelimit',
      'serverNow',
      'now',
      'extend',
      'prob',
      'problemid',
      'problemId',
      'id',
      'problemType',
      'problemtype',
      'problem_type',
    ]) {
      final value = event.payload[key] ?? raw[key];
      if (value != null) payload[key] = value;
    }
    return payload;
  }

  Future<void> inspectEvent(ClassroomEvent event) async {
    if (closing) return;
    if (event.op != 'heartbeat') {
      await store.appendLog('event op=${event.op}');
    }
    if (event.op == 'hello') {
      final authorized =
          event.payload['status'] != false &&
          event.payload['message'] != 'authorize failed';
      if (!authorized) {
        await store.appendLog('background auth failed');
        await updateNotification('课堂认证失败，请回 App 重新连接');
        await shutdownOwner();
        return;
      }
      await updateNotification('课堂认证成功，等待老师发题');
      final timeline = event.payload['timeline'];
      if (timeline is List) await inspectTimeline(timeline);
      final unlocked = event.payload['unlockedproblem'];
      if (unlocked is Map) {
        final problem = YktProblem.fromJson(
          Map<String, dynamic>.from(unlocked),
          published: true,
          source: ProblemSource.timeline,
          receivedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await coordinator.observePublish(problem, live: false);
      }
      await coordinator.runDueJobs(lease: lease);
      return;
    }

    if (event.op == 'unlockproblem' || event.op == 'problemon') {
      final problem = YktProblem.fromJson(
        eventProblemPayload(event),
        published: true,
        source: ProblemSource.liveEvent,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
      );
      if (problem.id.isEmpty) return;
      await updateNotification('老师发布了随堂习题：${problem.title}');
      await coordinator.observePublish(problem, live: true);
      await coordinator.runDueJobs(lease: lease);
      return;
    }

    if (event.op == 'fetchtimeline' || event.op == 'timeline') {
      final timeline = event.payload['timeline'];
      if (timeline is List) await inspectTimeline(timeline);
      await coordinator.runDueJobs(lease: lease);
      return;
    }

    if (event.op == 'problemfinished' ||
        event.op == 'closeproblem' ||
        event.op == 'problemoff') {
      final payload = event.payload['problem'] is Map
          ? Map<String, dynamic>.from(event.payload['problem'] as Map)
          : event.payload;
      final id =
          '${payload['prob'] ?? payload['problemid'] ?? payload['problemId'] ?? payload['id'] ?? ''}'
              .replaceFirst(RegExp(r'^prob-'), '');
      if (id.isNotEmpty) await coordinator.observeClose(id);
      return;
    }

    if (const {
      'lessonfinished',
      'lessonend',
      'lessonoff',
      'classover',
    }.contains(event.op)) {
      await coordinator.observeLessonEnded();
      await updateNotification('课堂已结束，自动提交任务已停止');
    }
  }

  void enqueueEvent(ClassroomEvent event) {
    eventQueue = eventQueue.then((_) => inspectEvent(event)).catchError((
      Object error,
      StackTrace stack,
    ) {
      unawaited(store.appendLog('event error $error'));
    });
  }

  var reconnectAttempts = 0;
  late Future<void> Function() connect;

  void scheduleReconnect() {
    if (closing) return;
    reconnectTimer?.cancel();
    timelineTimer?.cancel();
    final delaySeconds = (2 << reconnectAttempts).clamp(2, 30);
    reconnectAttempts++;
    reconnectTimer = Timer(Duration(seconds: delaySeconds), () {
      unawaited(connect());
    });
  }

  connect = () async {
    if (closing) return;
    await store.appendLog('service connect lesson=${context.lessonId}');
    await socketSubscription?.cancel();
    await socket?.close(lessonId: context.lessonId);
    socket = YktSocket.connect(
      session: session,
      lessonId: context.lessonId,
      lessonToken: context.lessonToken,
    );
    socketSubscription = socket!.events.listen(
      (event) {
        reconnectAttempts = 0;
        enqueueEvent(event);
      },
      onError: (_) => scheduleReconnect(),
      onDone: scheduleReconnect,
    );
    await updateNotification('已连接课堂，等待老师发题');
    timelineTimer?.cancel();
    timelineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      socket?.send({
        'op': 'fetchtimeline',
        'lessonid': context.lessonId,
        'msgid': DateTime.now().millisecondsSinceEpoch,
      });
    });
  };

  submissionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
    unawaited(coordinator.runDueJobs(lease: lease));
  });
  leaseTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
    final renewed = await store.renewOwner(lease);
    if (renewed == null) {
      await store.appendLog('background lease lost');
      await shutdownOwner();
    } else {
      lease = renewed;
    }
  });

  service.on('stop').listen((_) async {
    await shutdownOwner();
  });

  await store.appendLog(
    'service started lesson=${context.lessonId} '
    'owner=${lease.owner.name} generation=${lease.generation}',
  );
  await connect();
}
