import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../models/background_lesson_context.dart';
import '../models/classroom_event.dart';
import '../models/problem_view_state.dart';
import '../models/submission_job.dart';
import '../models/ykt_lesson.dart';
import '../models/ykt_presentation.dart';
import '../models/ykt_problem.dart';
import '../services/app_state.dart';
import '../services/background_auto_submit_service.dart';
import '../services/file_platform_helper.dart';
import '../services/presentation_exporter.dart';
import '../services/slide_cache_service.dart';
import '../services/submission_coordinator.dart';
import '../services/ykt_socket.dart';
import '../widgets/quiz_sheet.dart';

class ClassroomScreen extends StatefulWidget {
  const ClassroomScreen({
    required this.state,
    required this.lesson,
    required this.initialCheckin,
    super.key,
  });

  final AppState state;
  final YktLesson lesson;
  final CheckinResult initialCheckin;

  @override
  State<ClassroomScreen> createState() => _ClassroomScreenState();
}

class _ClassroomScreenState extends State<ClassroomScreen>
    with WidgetsBindingObserver {
  late CheckinResult _ticket;
  late List<PresentationSummary> _presentations;
  List<PresentationSlide> _slides = const [];
  final Map<String, YktProblem> _problems = {};
  final List<ClassroomEvent> _events = [];
  final Set<String> _closedProblemIds = {};
  final PageController _pageController = PageController();
  final Map<String, ValueNotifier<ProblemViewState>> _problemViews = {};
  final Set<String> _pendingPublishPromptKeys = {};
  final Set<String> _announcedPublishKeys = {};
  final Set<String> _announcedAutoSubmitKeys = {};

  YktSocket? _socket;
  StreamSubscription<ClassroomEvent>? _socketSubscription;
  Timer? _clock;
  Timer? _timelineRefreshTimer;
  Timer? _submissionSweep;
  Timer? _ownerLeaseTimer;
  String _selectedPresentationId = '';
  String _teacherPresentationId = '';
  int _currentSlide = 0;
  int _teacherSlide = 0;
  int _presentationRevision = 0;
  int _selectedTab = 0;
  bool _loadingPresentation = true;
  bool _refreshingClassroom = false;
  bool _followingTeacher = true;
  bool _wsConnected = false;
  bool _authFailed = false;
  String? _error;
  int _timelineMsgId = 1;
  RuntimeLease? _runtimeLease;
  SubmissionCoordinator? _submissionCoordinator;
  bool _sweepInProgress = false;
  final SlideCacheService _slideCache = SlideCacheService();
  DateTime? _lastSocketEventAt;
  DateTime? _lastPingSentAt;
  int? _wsLatencyMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticket = widget.initialCheckin;
    _presentations = [..._ticket.presentations];
    _selectedPresentationId = _ticket.activePresentationId;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _startSubmissionSweep();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _timelineRefreshTimer?.cancel();
    _submissionSweep?.cancel();
    _ownerLeaseTimer?.cancel();
    _socketSubscription?.cancel();
    unawaited(_socket?.close(lessonId: widget.lesson.id));
    final lease = _runtimeLease;
    if (lease != null) {
      unawaited(widget.state.autoSubmitStore.releaseOwner(lease));
    }
    for (final notifier in _problemViews.values) {
      notifier.dispose();
    }
    _pageController.dispose();
    _slideCache.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      unawaited(_enterBackgroundMode());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_leaveBackgroundMode());
    }
  }

  Future<void> _enterBackgroundMode() async {
    _submissionSweep?.cancel();
    _ownerLeaseTimer?.cancel();
    await _saveBackgroundContext();
    await _socketSubscription?.cancel();
    await _socket?.close(lessonId: widget.lesson.id);
    _socket = null;
    _socketSubscription = null;
    final lease = _runtimeLease;
    _runtimeLease = null;
    if (lease != null) {
      await widget.state.autoSubmitStore.releaseOwner(lease);
    }
    if (widget.state.autoSubmitEnabled) {
      await BackgroundAutoSubmitService.start();
    }
  }

  Future<void> _leaveBackgroundMode() async {
    await BackgroundAutoSubmitService.stopAndWait();
    final ownsForeground = await _claimForegroundOwner();
    if (mounted && ownsForeground && _ticket.lessonToken.isNotEmpty) {
      _startSubmissionSweep();
      _startOwnerLeaseRenewal();
      _connectSocket();
      await _runDueSubmissions();
    }
  }

  Future<void> _saveBackgroundContext() async {
    final session = widget.state.session;
    if (session == null || _ticket.lessonToken.isEmpty) return;
    await widget.state.store.saveBackgroundContext(
      BackgroundLessonContext(
        lessonId: widget.lesson.id,
        lessonName: widget.lesson.name,
        lessonToken: _ticket.lessonToken,
        bearerToken: _ticket.bearerToken,
        serverId: session.server.id,
        userId: session.userId,
      ),
    );
  }

  Future<bool> _claimForegroundOwner() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final lease = await widget.state.autoSubmitStore.acquireOwner(
        owner: RuntimeOwner.foreground,
        lessonId: widget.lesson.id,
      );
      if (lease.owner == RuntimeOwner.foreground) {
        _runtimeLease = lease;
        return true;
      }
      await BackgroundAutoSubmitService.stopAndWait();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _runtimeLease = null;
    return false;
  }

  Future<void> _handleAuthFailure() async {
    _wsConnected = false;
    _authFailed = true;
    _submissionSweep?.cancel();
    _ownerLeaseTimer?.cancel();
    final lease = _runtimeLease;
    _runtimeLease = null;
    if (lease != null) {
      await widget.state.autoSubmitStore.releaseOwner(lease);
    }
    await _socketSubscription?.cancel();
    await _socket?.close(lessonId: widget.lesson.id);
    _socket = null;
    _socketSubscription = null;
    if (mounted) setState(() {});
  }

  void _startSubmissionSweep() {
    _submissionSweep?.cancel();
    _submissionSweep = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_runDueSubmissions());
    });
  }

  void _startOwnerLeaseRenewal() {
    _ownerLeaseTimer?.cancel();
    _ownerLeaseTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      final lease = _runtimeLease;
      if (lease == null) return;
      final renewed = await widget.state.autoSubmitStore.renewOwner(lease);
      if (renewed == null) {
        _runtimeLease = null;
        if (mounted) {
          setState(() => _wsConnected = false);
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('课堂连接所有权已失效，正在重新同步')));
          await _initialize();
        }
      } else {
        _runtimeLease = renewed;
      }
    });
  }

  SubmissionCoordinator? _ensureCoordinator() {
    final session = widget.state.session;
    if (session == null) return null;
    final coordinator = _submissionCoordinator;
    if (coordinator != null) return coordinator;
    final created = SubmissionCoordinator(
      api: widget.state.api,
      store: widget.state.autoSubmitStore,
      session: session,
      lessonId: widget.lesson.id,
      bearerToken: _ticket.bearerToken,
      allowOvertime: widget.state.allowOvertime,
      onJobChanged: _handleJobChanged,
    );
    _submissionCoordinator = created;
    return created;
  }

  Future<void> _handleJobChanged(SubmissionJob job) async {
    final problem = _problems[job.problemId];
    if (problem != null) {
      if (job.state == SubmissionJobState.succeeded) {
        problem.markAnswerState(ProblemAnswerState.submittedByMe);
        problem.userAnswer = job.draft.answer;
      } else if (job.state == SubmissionJobState.alreadyAnswered) {
        problem.markAnswerState(ProblemAnswerState.answeredElsewhere);
      } else if (job.state == SubmissionJobState.authBlocked) {
        await _handleAuthFailure();
      }
    }
    await _refreshProblemView(job.problemId);
    if (!mounted) return;
    setState(() {});
    if (job.state == SubmissionJobState.scheduled &&
        job.trigger == SubmissionTrigger.automatic) {
      final publishKey = _publishPromptKey(job.problemId, job.publishEpoch);
      if (!_pendingPublishPromptKeys.contains(publishKey) &&
          _announcedAutoSubmitKeys.add(job.key)) {
        _showAutoSubmitNotice(job);
      }
    } else if (job.state == SubmissionJobState.succeeded &&
        job.trigger == SubmissionTrigger.automatic) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已自动提交预选答案：${job.title}')));
    } else if (job.state == SubmissionJobState.alreadyAnswered &&
        job.trigger == SubmissionTrigger.automatic) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('题目已在其他客户端作答：${job.title}')));
    }
  }

  String _publishPromptKey(String problemId, int publishEpoch) {
    return '$problemId:$publishEpoch';
  }

  int _secondsUntilScheduled(SubmissionJob job) {
    final remaining = job.scheduledAt - DateTime.now().millisecondsSinceEpoch;
    return remaining <= 0 ? 0 : (remaining / 1000).ceil();
  }

  void _showPublishedNotice(YktProblem problem, {SubmissionJob? scheduledJob}) {
    final messenger = ScaffoldMessenger.of(context);
    final seconds = scheduledJob == null
        ? 0
        : _secondsUntilScheduled(scheduledJob);
    final autoText = scheduledJob == null
        ? ''
        : seconds <= 0
        ? '，预选答案正在自动提交'
        : '，预选答案将在 $seconds 秒后自动提交';
    messenger.showSnackBar(
      SnackBar(
        duration: Duration(seconds: scheduledJob == null ? 4 : 7),
        content: Text('老师发布了随堂习题：${problem.title}$autoText'),
        action: scheduledJob == null
            ? SnackBarAction(
                label: '查看',
                onPressed: () => unawaited(_showProblem(problem)),
              )
            : SnackBarAction(
                label: '取消提交',
                onPressed: () => unawaited(_cancelAutoSubmit(scheduledJob)),
              ),
      ),
    );
  }

  void _showAutoSubmitNotice(SubmissionJob job) {
    final seconds = _secondsUntilScheduled(job);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: Duration(seconds: seconds <= 0 ? 5 : seconds + 4),
        content: Text(
          seconds <= 0
              ? '已匹配预选答案，正在自动提交：${job.title}'
              : '已匹配预选答案，将在 $seconds 秒后自动提交：${job.title}',
        ),
        action: SnackBarAction(
          label: '取消',
          onPressed: () => unawaited(_cancelAutoSubmit(job)),
        ),
      ),
    );
  }

  Future<void> _cancelAutoSubmit(SubmissionJob job) async {
    final coordinator = _ensureCoordinator();
    if (coordinator == null) return;
    final cancelled = await coordinator.cancelAutomaticSubmission(
      job.problemId,
    );
    _announcedAutoSubmitKeys.remove(job.key);
    await _refreshProblemView(job.problemId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(cancelled ? '已取消自动提交，预选答案仍然保留' : '自动提交已经开始，当前无法取消'),
      ),
    );
  }

  Future<void> _handleLivePublishedProblem(YktProblem problem) async {
    final key = _publishPromptKey(problem.id, problem.dt);
    final isFirstPrompt = !_announcedPublishKeys.contains(key);
    if (isFirstPrompt) _pendingPublishPromptKeys.add(key);
    SubmissionJob? scheduledJob;
    try {
      final coordinator = _ensureCoordinator();
      scheduledJob = await coordinator?.observePublish(problem, live: true);
    } finally {
      _pendingPublishPromptKeys.remove(key);
    }
    if (!mounted || !isFirstPrompt || !_announcedPublishKeys.add(key)) return;
    if (scheduledJob?.state == SubmissionJobState.scheduled &&
        scheduledJob?.trigger == SubmissionTrigger.automatic) {
      _announcedAutoSubmitKeys.add(scheduledJob!.key);
    }
    _showPublishedNotice(
      problem,
      scheduledJob: scheduledJob?.state == SubmissionJobState.scheduled
          ? scheduledJob
          : null,
    );
  }

  Future<void> _refreshProblemView(String problemId) async {
    final problem = _problems[problemId];
    final notifier = _problemViews[problemId];
    if (problem == null || notifier == null) return;
    final draft = await widget.state.autoSubmitStore.readDraft(problemId);
    final job = await _submissionCoordinator?.latestJob(problemId);
    notifier.value = ProblemViewState(problem: problem, draft: draft, job: job);
  }

  Future<void> _runDueSubmissions() async {
    if (_sweepInProgress || !mounted || !widget.state.autoSubmitEnabled) return;
    final lease = _runtimeLease;
    final coordinator = _ensureCoordinator();
    if (lease == null || coordinator == null) return;
    _sweepInProgress = true;
    try {
      await coordinator.runDueJobs(lease: lease);
    } finally {
      _sweepInProgress = false;
    }
  }

  Future<void> _initialize() async {
    if (_ticket.lessonToken.isEmpty) {
      final cached = await widget.state.lessonToken(widget.lesson.id);
      if (cached != null) {
        _ticket = CheckinResult(
          code: 0,
          message: '复用课堂凭据',
          lessonToken: cached.lessonToken,
          bearerToken: cached.bearerToken,
          activePresentationId: cached.activePresentationId,
          presentations: _presentations,
        );
      } else {
        final result = await widget.state.checkIn(widget.lesson);
        if (!result.success) {
          setState(() => _error = result.message);
          return;
        }
        _ticket = result;
        _presentations = [...result.presentations];
      }
    }
    final session = widget.state.session;
    if (session == null) {
      setState(() => _error = '雨课堂登录状态已失效');
      return;
    }
    await BackgroundAutoSubmitService.stopAndWait();
    if (!await _claimForegroundOwner()) {
      setState(() => _error = '正在等待后台服务释放课堂连接，请重新同步');
      return;
    }
    _startOwnerLeaseRenewal();
    _ensureCoordinator();
    if (_presentations.isEmpty) {
      final info = await widget.state.api.fetchLessonInfo(
        session: session,
        lessonId: widget.lesson.id,
      );
      _presentations = info.presentations;
      if (_selectedPresentationId.isEmpty) {
        _selectedPresentationId = info.activePresentationId;
      }
    }
    await _loadPresentation(_selectedPresentationId);
    await _saveBackgroundContext();
    _connectSocket();
    await _runDueSubmissions();
  }

  Future<YktPresentation?> _loadPresentation(
    String? presentationId, {
    int? followIndex,
    bool forceRefresh = false,
  }) async {
    final session = widget.state.session;
    if (session == null) return null;
    setState(() {
      _loadingPresentation = true;
      _error = null;
    });
    if (kDebugMode) {
      debugPrint(
        '[ClassroomPresentation] refresh requested '
        'presentationId=${presentationId ?? ''} followIndex=$followIndex',
      );
    }
    final presentation = await widget.state.api.fetchPresentation(
      session: session,
      lessonId: widget.lesson.id,
      presentationId: presentationId ?? '',
      bearerToken: _ticket.bearerToken,
      forceRefresh: forceRefresh,
    );
    if (!mounted) return presentation;
    if (kDebugMode) {
      debugPrint(
        '[ClassroomPresentation] loaded id=${presentation.id} '
        'slides=${presentation.slides.length} empty=${presentation.empty}',
      );
    }
    final incomingSlides = presentation.slides;
    final keepExisting = incomingSlides.isEmpty && _slides.isNotEmpty;
    final effectiveSlides = keepExisting ? _slides : incomingSlides;
    final teacherTarget = followIndex ?? _teacherSlide;
    final teacherIndex = effectiveSlides.isEmpty
        ? 0
        : teacherTarget.clamp(0, effectiveSlides.length - 1);
    final currentTarget = _currentSlide.clamp(
      0,
      effectiveSlides.isEmpty ? 0 : effectiveSlides.length - 1,
    );
    if (forceRefresh) {
      for (final slide in {..._slides, ...effectiveSlides}) {
        if (slide.coverUrl.isNotEmpty) {
          unawaited(NetworkImage(slide.coverUrl).evict());
        }
      }
    }
    setState(() {
      _slides = effectiveSlides;
      if (presentation.id.isNotEmpty) {
        _selectedPresentationId = presentation.id;
      }
      _loadingPresentation = false;
      _teacherSlide = teacherIndex;
      _currentSlide = _followingTeacher ? teacherIndex : currentTarget;
      if (forceRefresh) _presentationRevision++;
      _scanEmbeddedProblems();
    });
    if (keepExisting && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('课件刷新失败，已保留上次加载的幻灯片')));
      });
    }
    _scheduleSlideSync();
    if (effectiveSlides.isNotEmpty) {
      final urls = effectiveSlides.map((s) => s.coverUrl).toList();
      final presId = presentation.id.isNotEmpty
          ? presentation.id
          : _selectedPresentationId;
      unawaited(_slideCache.prefetchSlides(presId, urls));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _slideCache.precacheAdjacentImages(context, urls, _currentSlide);
        }
      });
    }
    return presentation;
  }

  Future<void> _refreshClassroom() async {
    if (_refreshingClassroom) return;
    final session = widget.state.session;
    if (session == null) {
      setState(() => _authFailed = true);
      return;
    }
    setState(() => _refreshingClassroom = true);
    try {
      final info = await widget.state.api.fetchLessonInfo(
        session: session,
        lessonId: widget.lesson.id,
        forceRefresh: true,
      );
      if (!mounted) return;
      if (info.presentations.isNotEmpty) {
        _presentations = [...info.presentations];
      }

      final presentationIds = info.presentations
          .map((presentation) => presentation.id)
          .toSet();
      final preferred = [
        _teacherPresentationId,
        info.activePresentationId,
        _selectedPresentationId,
      ];
      var presentationId = preferred.firstWhere(
        (id) =>
            id.isNotEmpty &&
            (presentationIds.isEmpty || presentationIds.contains(id)),
        orElse: () => '',
      );
      if (presentationId.isEmpty && info.activePresentationId.isNotEmpty) {
        presentationId = info.activePresentationId;
      }
      if (presentationId.isEmpty) presentationId = _selectedPresentationId;

      final presentation = await _loadPresentation(
        presentationId,
        followIndex: _teacherSlide,
        forceRefresh: true,
      );
      if (!mounted) return;
      if (_socket == null || !_wsConnected) {
        _connectSocket();
      } else {
        _socket?.send({
          'op': 'fetchtimeline',
          'lessonid': widget.lesson.id,
          'msgid': _timelineMsgId++,
        });
      }

      final success =
          presentation != null &&
          !presentation.empty &&
          presentation.slides.isNotEmpty;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '课堂已同步，当前课件 ${presentation.slides.length} 页'
                : '刷新请求已完成，但没有获取到新的课件内容',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('同步课堂失败：$error')));
    } finally {
      if (mounted) setState(() => _refreshingClassroom = false);
    }
  }

  void _scanEmbeddedProblems() {
    for (final slide in _slides) {
      final raw = slide.embeddedProblem;
      if (raw == null) continue;
      final payload = _problemPayload(raw);
      final id = _problemId(payload);
      if (id.isEmpty) continue;
      final existing = _problems[id];
      final mergedRaw = {...existing?.raw ?? const {}, ...payload};
      final problem = YktProblem.fromJson(
        mergedRaw,
        published: existing?.isPublished ?? false,
        source: ProblemSource.embedded,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
        presentationId: _selectedPresentationId,
        page: slide.index + 1,
        slideIndex: slide.index,
        coverUrl: slide.coverUrl,
      );
      if (existing != null) _preserveExtendedDeadline(problem, existing);
      if (existing == null) {
        _problems[problem.id] = problem;
      } else {
        final merged = YktProblem.fromJson(
          mergedRaw,
          published: existing.isPublished,
          source: existing.source,
          receivedAt: existing.receivedAt,
          presentationId: existing.presentationId,
          page: existing.page,
          slideIndex: existing.slideIndex,
          coverUrl: existing.coverUrl,
        )..markAnswerState(_mergeAnswerState(existing, problem.answerState));
        _preserveExtendedDeadline(merged, existing);
        if (existing.isClosed) merged.markClosed();
        _problems[id] = merged;
      }
      unawaited(_refreshProblemView(id));
    }
  }

  void _ingestTimelineProblems(List timeline, [List<YktProblem>? collected]) {
    for (final item in timeline) {
      if (item is! Map) continue;
      final raw = Map<String, dynamic>.from(item);
      final type = '${raw['type'] ?? raw['op'] ?? ''}'.toLowerCase();
      final nested = raw['problem'];
      final payload = _problemPayload(raw);
      final id = _problemId(payload);
      if (id.isEmpty ||
          (type != 'problem' &&
              type != 'embedded_problem' &&
              nested is! Map &&
              raw['prob'] == null &&
              raw['problemid'] == null &&
              raw['problemId'] == null)) {
        continue;
      }
      final existing = _problems[id];
      final rawPage = int.tryParse(
        '${raw['si'] ?? raw['page'] ?? raw['slideindex'] ?? raw['slideIndex'] ?? existing?.page ?? 1}',
      );
      final slideIndex = rawPage == null || rawPage <= 0
          ? existing?.slideIndex ?? 0
          : rawPage - 1;
      final presentationId =
          '${raw['pres'] ?? raw['presentation'] ?? existing?.presentationId ?? _selectedPresentationId}';
      final cover =
          slideIndex != (existing?.slideIndex ?? -1) &&
              slideIndex >= 0 &&
              slideIndex < _slides.length
          ? _slides[slideIndex].coverUrl
          : existing?.coverUrl ?? '';
      final mergedRaw = {...existing?.raw ?? const {}, ...payload};
      if (raw['dt'] != null) mergedRaw['dt'] = raw['dt'];
      if (raw['time'] != null) mergedRaw['time'] = raw['time'];
      if (raw['limit'] != null) mergedRaw['limit'] = raw['limit'];
      if (raw['serverNow'] != null) {
        mergedRaw['serverNow'] = raw['serverNow'];
      }
      if (raw['now'] != null) mergedRaw['now'] = raw['now'];
      final problem = YktProblem.fromJson(
        mergedRaw,
        published: true,
        source: ProblemSource.timeline,
        receivedAt: DateTime.now().millisecondsSinceEpoch,
        presentationId: presentationId,
        page: rawPage == null || rawPage <= 0 ? existing?.page ?? 1 : rawPage,
        slideIndex: slideIndex,
        coverUrl: cover,
      );
      if (existing != null) {
        _preserveExtendedDeadline(problem, existing);
        problem.markAnswerState(
          _mergeAnswerState(existing, problem.answerState),
        );
        if (existing.boundary == ProblemBoundary.teacherClosed) {
          problem.markClosed();
        } else if (existing.boundary == ProblemBoundary.lessonEnded) {
          problem.markLessonEnded();
        }
        problem.userAnswer ??= existing.userAnswer;
      }
      if (_closedProblemIds.contains(id)) problem.markClosed();
      _problems[id] = problem;
      collected?.add(problem);
      unawaited(_refreshProblemView(id));
    }
  }

  Map<String, dynamic> _problemPayload(Map<String, dynamic> raw) {
    final nested = raw['problem'];
    final payload = nested is Map
        ? Map<String, dynamic>.from(nested)
        : <String, dynamic>{};
    if (nested is! Map) payload.addAll(raw);
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
    ]) {
      if (raw[key] != null) payload[key] = raw[key];
    }
    return payload;
  }

  Map<String, dynamic> _eventProblemPayload(ClassroomEvent event) {
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

  String _problemId(Map<String, dynamic> problem) {
    return '${problem['prob'] ?? problem['problemid'] ?? problem['problemId'] ?? problem['id'] ?? ''}'
        .replaceFirst(RegExp(r'^prob-'), '');
  }

  ProblemAnswerState _mergeAnswerState(
    YktProblem existing,
    ProblemAnswerState incoming,
  ) {
    if (existing.answerState == ProblemAnswerState.submittedByMe) {
      return ProblemAnswerState.submittedByMe;
    }
    if (existing.answerState == ProblemAnswerState.answeredElsewhere) {
      return ProblemAnswerState.answeredElsewhere;
    }
    if (incoming != ProblemAnswerState.unanswered &&
        incoming != ProblemAnswerState.unknown) {
      return incoming;
    }
    return existing.answerState;
  }

  void _preserveExtendedDeadline(YktProblem incoming, YktProblem existing) {
    if (existing.extend <= 0 || incoming.limit > existing.limit) return;
    incoming.limit = existing.limit;
    incoming.extend = existing.extend;
    incoming.deadlineRevision = existing.deadlineRevision;
  }

  void _connectSocket() {
    final session = widget.state.session;
    if (session == null || _ticket.lessonToken.isEmpty) return;
    unawaited(_socketSubscription?.cancel());
    unawaited(_socket?.close(lessonId: widget.lesson.id));
    final socket = YktSocket.connect(
      session: session,
      lessonId: widget.lesson.id,
      lessonToken: _ticket.lessonToken,
    );
    _socket = socket;
    _socketSubscription = socket.events.listen(
      _handleSocketEvent,
      onError: (_) {
        if (mounted) setState(() => _wsConnected = false);
      },
      onDone: () {
        if (mounted) setState(() => _wsConnected = false);
      },
    );
  }

  void _handleSocketEvent(ClassroomEvent event) {
    if (!mounted) return;
    _lastSocketEventAt = DateTime.now();
    if (_lastPingSentAt != null &&
        (event.op == 'pong' || event.op == 'hello' || event.op == 'fetchtimeline')) {
      _wsLatencyMs = DateTime.now().difference(_lastPingSentAt!).inMilliseconds;
      _lastPingSentAt = null;
    }
    String? presentationToLoad;
    int? presentationTargetIndex;
    YktProblem? unlockedProblem;
    YktProblem? helloUnlockedProblem;
    String? closedProblemId;
    final timelineProblems = <YktProblem>[];
    int? extendedSeconds;
    var helloAuthorized = false;
    var lessonEnded = false;
    setState(() {
      if (event.op == 'hello') {
        final authorized =
            event.payload['status'] != false &&
            event.payload['message'] != 'authorize failed';
        helloAuthorized = authorized;
        _wsConnected = authorized;
        if (authorized) _authFailed = false;
        var presentationId = event.presentationId;
        if (presentationId.isEmpty) {
          final timeline = event.payload['timeline'];
          if (timeline is List) {
            for (final item in timeline.reversed) {
              if (item is Map) {
                final id =
                    '${item['pres'] ?? item['presentation'] ?? item['presentationid'] ?? ''}';
                if (id.isNotEmpty) {
                  presentationId = id;
                  break;
                }
              }
            }
          }
        }
        if (presentationId.isNotEmpty &&
            (_selectedPresentationId.isEmpty ||
                presentationId != _selectedPresentationId ||
                _slides.isEmpty)) {
          presentationToLoad = presentationId;
        }
        if (presentationId.isNotEmpty) {
          _teacherPresentationId = presentationId;
        }
        final slideIndex = event.slideIndex ?? _slideIndexFromTimeline(event);
        if (slideIndex != null && slideIndex < _slides.length) {
          _teacherSlide = slideIndex;
          _currentSlide = slideIndex;
        }
        if (slideIndex != null) presentationTargetIndex = slideIndex;
        if (kDebugMode) {
          debugPrint(
            '[ClassroomSocket] hello connected=$authorized '
            'presentation=$presentationId keys=${event.payload.keys.join(',')}',
          );
        }
        final timeline = event.payload['timeline'];
        if (timeline is List) {
          _ingestTimelineProblems(timeline, timelineProblems);
        }
        final unlocked = event.payload['unlockedproblem'];
        if (unlocked is Map) {
          final payload = _problemPayload(Map<String, dynamic>.from(unlocked));
          final id = _problemId(payload);
          final existing = _problems[id];
          final mergedRaw = {...existing?.raw ?? const {}, ...payload};
          final problem = YktProblem.fromJson(
            mergedRaw,
            published: true,
            source: ProblemSource.timeline,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
            presentationId: existing?.presentationId ?? _selectedPresentationId,
            page: existing?.page ?? _currentSlide + 1,
            slideIndex: existing?.slideIndex ?? _currentSlide,
            coverUrl:
                existing?.coverUrl ??
                (_currentSlide < _slides.length
                    ? _slides[_currentSlide].coverUrl
                    : ''),
          );
          if (problem.id.isNotEmpty) {
            if (existing != null) {
              _preserveExtendedDeadline(problem, existing);
              problem.markAnswerState(
                _mergeAnswerState(existing, problem.answerState),
              );
              if (existing.isClosed) problem.markClosed();
            }
            _problems[problem.id] = problem;
            helloUnlockedProblem = problem;
            unawaited(_refreshProblemView(problem.id));
          }
        }
        _timelineRefreshTimer?.cancel();
        _timelineRefreshTimer = Timer(const Duration(milliseconds: 350), () {
          _socket?.send({
            'op': 'fetchtimeline',
            'lessonid': widget.lesson.id,
            'msgid': _timelineMsgId++,
          });
        });
      }
      if (event.op != 'heartbeat') {
        _events.insert(0, event);
        if (_events.length > 150) {
          _events.removeRange(150, _events.length);
        }
      }

      if (const {
        'slidenav',
        'slide',
        'slideshow',
        'presentationupdated',
        'slideupdated',
        'presentationon',
      }.contains(event.op)) {
        final presentationId = event.presentationId;
        if (presentationId.isNotEmpty &&
            presentationId != _selectedPresentationId) {
          presentationToLoad = presentationId;
        }
        if (presentationId.isNotEmpty) {
          _teacherPresentationId = presentationId;
        }
        final slideIndex = event.slideIndex;
        if (slideIndex != null) {
          _teacherSlide = slideIndex;
          if (_followingTeacher) {
            _currentSlide = slideIndex;
          }
        }
        if (kDebugMode) {
          debugPrint(
            '[ClassroomSocket] op=${event.op} slide=${event.slideIndex} '
            'presentation=${event.presentationId} '
            'keys=${event.payload.keys.join(',')}',
          );
        }
      }

      if (event.op == 'showpresentation' ||
          event.op == 'presentationstart' ||
          event.op == 'presentationcreated') {
        final presentationId = event.presentationId;
        if (presentationId.isNotEmpty) {
          _teacherPresentationId = presentationId;
          presentationToLoad = presentationId;
        }
      }

      if (event.op == 'unlockproblem' || event.op == 'problemon') {
        final raw = event.problem;
        if (raw != null) {
          final payload = _eventProblemPayload(event);
          final id = _problemId(payload);
          final existing = _problems[id];
          final mergedRaw = {...existing?.raw ?? const {}, ...payload};
          final problem = YktProblem.fromJson(
            mergedRaw,
            published: true,
            source: ProblemSource.liveEvent,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
            presentationId: event.presentationId.isEmpty
                ? existing?.presentationId ?? _selectedPresentationId
                : event.presentationId,
            page: existing?.page ?? _currentSlide + 1,
            slideIndex: existing?.slideIndex ?? _currentSlide,
            coverUrl:
                existing?.coverUrl ??
                (_currentSlide < _slides.length
                    ? _slides[_currentSlide].coverUrl
                    : ''),
          );
          if (problem.id.isNotEmpty) {
            _closedProblemIds.remove(problem.id);
            if (existing != null) {
              _preserveExtendedDeadline(problem, existing);
              problem.markAnswerState(
                _mergeAnswerState(existing, problem.answerState),
              );
              problem.userAnswer ??= existing.userAnswer;
            }
            _problems[problem.id] = problem;
            unlockedProblem = problem;
            unawaited(_refreshProblemView(problem.id));
          }
        }
      }

      if (event.op == 'probleminfo') {
        final payload = _problemPayload(event.payload);
        final id = _problemId(payload);
        final existing = _problems[id];
        if (existing != null) {
          final mergedRaw = {...existing.raw, ...payload};
          final refreshed = YktProblem.fromJson(
            mergedRaw,
            published: existing.isPublished,
            source: existing.source,
            receivedAt: DateTime.now().millisecondsSinceEpoch,
            presentationId: existing.presentationId,
            page: existing.page,
            slideIndex: existing.slideIndex,
            coverUrl: existing.coverUrl,
          );
          _preserveExtendedDeadline(refreshed, existing);
          refreshed.markAnswerState(
            _mergeAnswerState(existing, refreshed.answerState),
          );
          if (existing.isClosed) refreshed.markClosed();
          _problems[id] = refreshed;
          unawaited(_refreshProblemView(id));
        }
      }

      if (event.op == 'extendtime') {
        final payload = event.payload;
        final nested = _problemPayload(payload);
        final id = _problemId(nested);
        final requestedExtend = int.tryParse(
          '${nested['extend'] ?? payload['extend'] ?? 0}',
        );
        final absoluteLimit = int.tryParse(
          '${nested['limit'] ?? nested['timelimit'] ?? payload['limit'] ?? payload['timelimit'] ?? 0}',
        );
        final target = _problems[id];
        if (target != null) {
          _closedProblemIds.remove(id);
          extendedSeconds = target.extendBy(
            requestedExtend ?? 0,
            absoluteLimit: absoluteLimit,
          );
          unawaited(_refreshProblemView(id));
        }
      }

      if (event.op == 'problemfinished' ||
          event.op == 'closeproblem' ||
          event.op == 'problemoff') {
        final id = _problemId(_problemPayload(event.payload));
        if (id.isNotEmpty) _closedProblemIds.add(id);
        final target = _problems[id];
        if (target != null) {
          target.markClosed();
          closedProblemId = id;
          unawaited(_refreshProblemView(id));
        }
      }

      if (const {
        'lessonfinished',
        'lessonend',
        'lessonoff',
        'classover',
      }.contains(event.op)) {
        lessonEnded = true;
        for (final problem in _problems.values) {
          problem.markLessonEnded();
          unawaited(_refreshProblemView(problem.id));
        }
      }

      if (event.op == 'fetchtimeline' || event.op == 'timeline') {
        final timeline = event.payload['timeline'];
        if (timeline is List) {
          _ingestTimelineProblems(timeline, timelineProblems);
        }
      }

      if (const {
        'callroll',
        'randompick',
        'callpaused',
        'callrollstop',
        'callrollpause',
      }.contains(event.op)) {
        final isSelf =
            event.payload['isSelf'] == true ||
            event.payload['type'] == 'callroll_self';
        if (isSelf) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('老师点到了你'),
                content: const Text('请准备发言。'),
                actions: [
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('收到'),
                  ),
                ],
              ),
            );
          });
        }
      }
    });
    if (!helloAuthorized && event.op == 'hello') {
      unawaited(_handleAuthFailure());
    }
    final coordinator = _ensureCoordinator();
    if (coordinator != null) {
      for (final problem in timelineProblems) {
        unawaited(coordinator.observePublish(problem, live: false));
      }
    }
    if (helloUnlockedProblem != null && coordinator != null) {
      unawaited(coordinator.observePublish(helloUnlockedProblem!, live: false));
    }
    if (unlockedProblem != null) {
      unawaited(_handleLivePublishedProblem(unlockedProblem!));
    }
    if (closedProblemId != null && coordinator != null) {
      unawaited(coordinator.observeClose(closedProblemId!));
    }
    if (lessonEnded && coordinator != null) {
      unawaited(coordinator.observeLessonEnded());
    }
    final extension = extendedSeconds;
    if (extension != null && extension > 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('答题时间已延长 $extension 秒')));
    }
    unawaited(_runDueSubmissions());
    if (presentationToLoad != null) {
      unawaited(
        _loadPresentation(
          presentationToLoad,
          followIndex: presentationTargetIndex,
        ),
      );
    } else {
      _scheduleSlideSync();
    }
  }

  void _scheduleSlideSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_followingTeacher ||
          !_pageController.hasClients ||
          _slides.isEmpty) {
        return;
      }
      final target = _currentSlide.clamp(0, _slides.length - 1);
      final currentPage = (_pageController.page ?? 0).round();
      if (currentPage != target) {
        _pageController.jumpToPage(target);
      }
    });
  }

  int? _slideIndexFromTimeline(ClassroomEvent event) {
    final timeline = event.payload['timeline'];
    if (timeline is! List) return null;
    for (final item in timeline.reversed) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      for (final key in ['si', 'slideindex', 'slideIndex', 'page', 'index']) {
        final value = int.tryParse('${map[key]}');
        if (value != null && value >= 0 && value < 1000) {
          return value > 0 ? value - 1 : 0;
        }
      }
    }
    return null;
  }

  void _selectSlide(int index) {
    if (index < 0 || index >= _slides.length) return;
    setState(() {
      _currentSlide = index;
      _followingTeacher = index == _teacherSlide;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  Future<void> _showProblem(YktProblem problem) async {
    final session = widget.state.session;
    if (session == null) return;
    final coordinator = _ensureCoordinator();
    final lease = _runtimeLease;
    if (coordinator == null || lease == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('课堂尚未建立有效连接，请稍后重试')));
      return;
    }
    final draft = await widget.state.autoSubmitStore.readDraft(problem.id);
    final job = await coordinator.latestJob(problem.id);
    if (!mounted) return;
    final notifier = _problemViews.putIfAbsent(
      problem.id,
      () => ValueNotifier(
        ProblemViewState(problem: problem, draft: draft, job: job),
      ),
    );
    notifier.value = ProblemViewState(problem: problem, draft: draft, job: job);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFFF8F7F3),
      builder: (context) {
        return QuizSheet(
          viewListenable: notifier,
          allowOvertime: widget.state.allowOvertime,
          autoSubmitEnabled: widget.state.autoSubmitEnabled,
          autoSubmitDelaySeconds: widget.state.autoSubmitDelaySeconds,
          uploadImage: (XFile file) =>
              widget.state.api.uploadAnswerImage(session: session, file: file),
          onSavePreselection: (draft) async {
            final current = _problems[problem.id];
            if (current == null) return;
            await coordinator.savePreselection(current, draft);
            await _refreshProblemView(problem.id);
            await _runDueSubmissions();
          },
          onClearPreselection: (problemId) async {
            await coordinator.clearPreselection(problemId);
            await _refreshProblemView(problemId);
          },
          onCancelAutoSubmit: () async {
            final currentJob = await coordinator.latestJob(problem.id);
            if (currentJob != null) await _cancelAutoSubmit(currentJob);
          },
          onSubmit: (answer, retry) async {
            final current = _problems[problem.id];
            if (current == null) {
              return const AnswerSubmitResult(
                success: false,
                message: '题目状态已失效，请重新打开',
              );
            }
            try {
              final result = await coordinator.submitManual(
                problem: current,
                answer: answer,
                retry: retry,
                lease: lease,
              );
              await _refreshProblemView(problem.id);
              if (mounted) setState(() {});
              return result;
            } on SubmissionBusyException {
              return const AnswerSubmitResult(
                success: false,
                code: 409,
                message: '该题正在自动提交，请等待结果',
              );
            }
          },
        );
      },
    );
    _problemViews.remove(problem.id)?.dispose();
    if (mounted) setState(() {});
  }

  Future<void> _openFullscreenSlide(int initialPage) async {
    final controller = PageController(initialPage: initialPage);
    await showDialog<void>(
      context: context,
      builder: (context) {
        var page = initialPage;
        return Dialog.fullscreen(
          backgroundColor: const Color(0xFF111614),
          child: SafeArea(
            child: Stack(
              children: [
                PageView.builder(
                  controller: controller,
                  itemCount: _slides.length,
                  onPageChanged: (value) => page = value,
                  itemBuilder: (context, index) {
                    final slide = _slides[index];
                    return InteractiveViewer(
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: slide.coverUrl.isEmpty
                            ? const Text(
                                '此页暂无课件图片',
                                style: TextStyle(color: Colors.white70),
                              )
                            : Image.network(
                                slide.coverUrl,
                                key: ValueKey(
                                  'full:${slide.id}:${slide.coverUrl}:$_presentationRevision',
                                ),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white54,
                                  size: 48,
                                ),
                              ),
                      ),
                    );
                  },
                ),
                Positioned(
                  left: 16,
                  top: 12,
                  child: IconButton.filledTonal(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: '关闭',
                  ),
                ),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: StatefulBuilder(
                    builder: (context, setLocalState) {
                      return Text(
                        '${page + 1} / ${_slides.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    controller.dispose();
  }

  Future<void> _showExportDialog() async {
    if (_slides.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前课件暂无幻灯片可供导出')),
      );
      return;
    }

    final summary = _presentations.firstWhere(
      (p) => p.id == _selectedPresentationId,
      orElse: () => PresentationSummary(
        id: '',
        title: widget.lesson.name,
        slideCount: _slides.length,
      ),
    );
    final title = summary.title.isNotEmpty ? summary.title : widget.lesson.name;
    final presentation = YktPresentation(
      id: _selectedPresentationId,
      title: title,
      slides: _slides,
    );

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ExportPresentationSheet(
        presentation: presentation,
        lessonName: widget.lesson.name,
        customDirectoryPath: widget.state.exportDirectory,
      ),
    );
  }

  Future<void> _openConnectionDiagnostic() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => _ConnectionDiagnosticSheet(
        wsConnected: _wsConnected,
        authFailed: _authFailed,
        latencyMs: _wsLatencyMs,
        lastEventAt: _lastSocketEventAt,
        lessonId: widget.lesson.id,
        recentEvents: _events.take(12).toList(),
        onPing: () {
          setState(() => _lastPingSentAt = DateTime.now());
          _socket?.send({
            'op': 'fetchtimeline',
            'lessonid': widget.lesson.id,
            'msgid': _timelineMsgId++,
          });
          Navigator.pop(sheetCtx);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已发送心跳与时间线同步测试包')),
          );
        },
        onReconnect: () {
          Navigator.pop(sheetCtx);
          _connectSocket();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('正在强制重新建立 WebSocket 连接…')),
          );
        },
        onSyncAll: () {
          Navigator.pop(sheetCtx);
          _refreshClassroom();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.lesson.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 18),
            ),
            Text(
              _authFailed
                  ? '雨课堂登录已失效'
                  : _wsConnected
                  ? '实时课堂已连接'
                  : '正在同步课堂事件',
              style: TextStyle(
                fontSize: 11,
                color: _authFailed
                    ? const Color(0xFF9A3F35)
                    : _wsConnected
                    ? const Color(0xFF216B42)
                    : const Color(0xFF69716D),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '连接诊断',
            onPressed: _openConnectionDiagnostic,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.network_check_rounded),
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _authFailed
                          ? const Color(0xFFD93F34)
                          : _wsConnected
                              ? const Color(0xFF21B561)
                              : const Color(0xFFD97706),
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '导出课件',
            onPressed: _slides.isEmpty ? null : _showExportDialog,
            icon: const Icon(Icons.download_rounded),
          ),
          IconButton(
            tooltip: '同步课堂',
            onPressed: _refreshingClassroom ? null : _refreshClassroom,
            icon: _refreshingClassroom
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: _error != null
          ? _ErrorBody(message: _error!, onRetry: _initialize)
          : LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 920;
                final presentation = _buildPresentationPanel();
                final events = _buildEventPanel();
                if (wide) {
                  return Row(
                    children: [
                      Expanded(flex: 7, child: presentation),
                      const VerticalDivider(),
                      SizedBox(width: 380, child: events),
                    ],
                  );
                }
                return Column(
                  children: [
                    Expanded(flex: 6, child: presentation),
                    const Divider(),
                    Expanded(flex: 4, child: events),
                  ],
                );
              },
            ),
    );
  }

  Widget _buildPresentationPanel() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
          child: Row(
            children: [
              Expanded(
                child: _presentations.length <= 1
                    ? Text(
                        _selectedPresentationId.isEmpty
                            ? '课堂课件'
                            : '课件 ${_selectedPresentationId.substring(_selectedPresentationId.length > 8 ? _selectedPresentationId.length - 8 : 0)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      )
                    : DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value:
                              _presentations.any(
                                (item) => item.id == _selectedPresentationId,
                              )
                              ? _selectedPresentationId
                              : _presentations.first.id,
                          items: [
                            for (final item in _presentations)
                              DropdownMenuItem(
                                value: item.id,
                                child: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) _loadPresentation(value);
                          },
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Text(
                _slides.isEmpty
                    ? '0 页'
                    : '${_currentSlide + 1} / ${_slides.length}',
                style: const TextStyle(
                  color: Color(0xFF58615D),
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              IconButton(
                tooltip: '导出课件',
                onPressed: _slides.isEmpty ? null : _showExportDialog,
                icon: const Icon(Icons.file_download_outlined),
              ),
              IconButton(
                tooltip: '全屏',
                onPressed: _slides.isEmpty
                    ? null
                    : () => _openFullscreenSlide(_currentSlide),
                icon: const Icon(Icons.fullscreen_rounded),
              ),
            ],
          ),
        ),
        Expanded(
          child: _loadingPresentation
              ? const Center(child: CircularProgressIndicator())
              : _slides.isEmpty
              ? const Center(child: Text('老师尚未上传课件，或课件接口暂不可用'))
              : PageView.builder(
                  controller: _pageController,
                  itemCount: _slides.length,
                  onPageChanged: (index) {
                    setState(() {
                      _currentSlide = index;
                      _followingTeacher = index == _teacherSlide;
                    });
                    _slideCache.precacheAdjacentImages(
                      context,
                      _slides.map((s) => s.coverUrl).toList(),
                      index,
                    );
                  },
                  itemBuilder: (context, index) {
                    final slide = _slides[index];
                    return Container(
                      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF202622),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 5,
                        child: Center(
                          child: slide.coverUrl.isEmpty
                              ? const Icon(
                                  Icons.slideshow_outlined,
                                  size: 54,
                                  color: Colors.white54,
                                )
                              : _CachedSlideImage(
                                  key: ValueKey(
                                    '${slide.id}:${slide.coverUrl}:$_presentationRevision',
                                  ),
                                  cache: _slideCache,
                                  presentationId: _selectedPresentationId,
                                  url: slide.coverUrl,
                                ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (_slides.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一页',
                  onPressed: _currentSlide <= 0
                      ? null
                      : () => _selectSlide(_currentSlide - 1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _selectSlide(_teacherSlide),
                    icon: Icon(
                      _followingTeacher
                          ? Icons.link_rounded
                          : Icons.link_off_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _followingTeacher
                          ? '正在跟随老师'
                          : '跳到老师当前页 ${_teacherSlide + 1}',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一页',
                  onPressed: _currentSlide >= _slides.length - 1
                      ? null
                      : () => _selectSlide(_currentSlide + 1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildEventPanel() {
    final problems = _problems.values.toList()
      ..sort((a, b) => b.dt.compareTo(a.dt));
    final rollcalls = _events
        .where(
          (event) => const {
            'callroll',
            'randompick',
            'callpaused',
            'callrollstop',
            'callrollpause',
          }.contains(event.op),
        )
        .toList();
    final visibleEvents = switch (_selectedTab) {
      1 =>
        _events
            .where(
              (event) => {
                'unlockproblem',
                'problemon',
                'extendtime',
                'problemfinished',
                'closeproblem',
                'problemoff',
              }.contains(event.op),
            )
            .toList(),
      2 => rollcalls,
      _ => _events,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: SegmentedButton<int>(
            segments: [
              const ButtonSegment(value: 0, label: Text('全部')),
              ButtonSegment(value: 1, label: Text('习题 ${problems.length}')),
              ButtonSegment(value: 2, label: Text('点名 ${rollcalls.length}')),
            ],
            selected: {_selectedTab},
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              setState(() => _selectedTab = value.first);
            },
          ),
        ),
        Expanded(
          child: _selectedTab == 1 && problems.isNotEmpty
              ? ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: problems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final problem = problems[index];
                    return _ProblemTile(
                      problem: problem,
                      onTap: () => _showProblem(problem),
                    );
                  },
                )
              : visibleEvents.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      _selectedTab == 1
                          ? '老师还没有发布随堂习题'
                          : _selectedTab == 2
                          ? '暂无随机点名'
                          : '正在等待课堂实时事件',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF69716D)),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: visibleEvents.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _EventTile(event: visibleEvents[index]);
                  },
                ),
        ),
      ],
    );
  }
}

class _ProblemTile extends StatelessWidget {
  const _ProblemTile({required this.problem, required this.onTap});

  final YktProblem problem;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = problem.answerState == ProblemAnswerState.answeredElsewhere
        ? '其他端已答'
        : problem.answerState == ProblemAnswerState.submittedByMe
        ? '我已提交'
        : !problem.isPublished
        ? '课件内含'
        : problem.isClosed
        ? '已收题'
        : problem.isOverdue
        ? '已超时'
        : problem.limit > 0
        ? '${problem.remainingSeconds}s'
        : '已发布';
    final color = problem.answerState == ProblemAnswerState.submittedByMe
        ? const Color(0xFF216B42)
        : problem.answerState == ProblemAnswerState.answeredElsewhere ||
              problem.isClosed ||
              problem.isOverdue
        ? const Color(0xFFB85C1E)
        : const Color(0xFF176B62);
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                clipBehavior: Clip.antiAlias,
                child: problem.coverUrl.isNotEmpty
                    ? Image.network(
                        problem.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Icon(Icons.quiz_outlined, color: color),
                      )
                    : Icon(Icons.quiz_outlined, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      problem.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '第 ${problem.page} 页 · ${problem.isMultiple ? '多选' : '作答'}',
                      style: const TextStyle(
                        color: Color(0xFF69716D),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                status,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});

  final ClassroomEvent event;

  @override
  Widget build(BuildContext context) {
    final time =
        '${event.receivedAt.hour.toString().padLeft(2, '0')}:${event.receivedAt.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE6E3DA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFFE6F0ED),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              _eventIcon(event.op),
              size: 17,
              color: const Color(0xFF176B62),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  event.description,
                  style: const TextStyle(
                    color: Color(0xFF69716D),
                    height: 1.4,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Text(
            time,
            style: const TextStyle(color: Color(0xFF8A918D), fontSize: 11),
          ),
        ],
      ),
    );
  }

  IconData _eventIcon(String op) => switch (op) {
    'unlockproblem' || 'problemon' => Icons.quiz_outlined,
    'callroll' || 'randompick' => Icons.record_voice_over_outlined,
    'notification' => Icons.notifications_none_rounded,
    'slidenav' || 'slide' || 'slideshow' => Icons.slideshow_rounded,
    'redpack' || 'bonus' => Icons.card_giftcard_rounded,
    'rush' || 'quickanswer' => Icons.bolt_rounded,
    _ => Icons.sensors_rounded,
  };
}

class _ErrorBody extends StatelessWidget {
  const _ErrorBody({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 48),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新同步'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExportPresentationSheet extends StatefulWidget {
  const _ExportPresentationSheet({
    required this.presentation,
    required this.lessonName,
    this.customDirectoryPath,
  });

  final YktPresentation presentation;
  final String lessonName;
  final String? customDirectoryPath;

  @override
  State<_ExportPresentationSheet> createState() =>
      _ExportPresentationSheetState();
}

class _ExportPresentationSheetState extends State<_ExportPresentationSheet> {
  ExportFormat _format = ExportFormat.pdf;
  bool _exporting = false;
  PresentationExportProgress? _progress;
  ExportResult? _result;

  Future<void> _startExport() async {
    setState(() {
      _exporting = true;
      _result = null;
      _progress = const PresentationExportProgress(
        current: 0,
        total: 1,
        statusText: '正在准备课件幻灯片…',
      );
    });

    final exporter = PresentationExporter(
      customDirectoryPath: widget.customDirectoryPath,
    );
    final result = await exporter.export(
      presentation: widget.presentation,
      lessonName: widget.lessonName,
      format: _format,
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );

    if (mounted) {
      setState(() {
        _exporting = false;
        _result = result;
      });
    }
  }

  void _copyPath(String path) {
    Clipboard.setData(ClipboardData(text: path));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制文件保存路径到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final totalSlides = widget.presentation.slides.length;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF38433E) : const Color(0xFFD1D5D2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.file_download_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '导出课件',
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${widget.presentation.title} · 共 $totalSlides 页',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          if (_result == null) ...[
            Text(
              '选择导出格式',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: isDark ? const Color(0xFFCFD8D3) : const Color(0xFF424A46),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? const Color(0xFF2C3530) : const Color(0xFFE2DFD7),
                ),
              ),
              child: RadioGroup<ExportFormat>(
                groupValue: _format,
                onChanged: (v) {
                  if (!_exporting && v != null) {
                    setState(() => _format = v);
                  }
                },
                child: const Column(
                  children: [
                    RadioListTile<ExportFormat>(
                      value: ExportFormat.pdf,
                      secondary: Icon(Icons.picture_as_pdf_outlined),
                      title: Text('多页 PDF 文档 (.pdf)'),
                      subtitle: Text('将全部幻灯片合并为单份标准 PDF，适合打印和手写笔记'),
                    ),
                    Divider(height: 1),
                    RadioListTile<ExportFormat>(
                      value: ExportFormat.images,
                      secondary: Icon(Icons.photo_library_outlined),
                      title: Text('全部高清图片包 (.jpg)'),
                      subtitle: Text('按页码排序保存为完整图片文件夹，便于逐页提取引用'),
                    ),
                    Divider(height: 1),
                    RadioListTile<ExportFormat>(
                      value: ExportFormat.offlineHtml,
                      secondary: Icon(Icons.html_outlined),
                      title: Text('离线网页课件 (.html)'),
                      subtitle: Text('单个独立离线网页，可在任何浏览器直接全屏翻页阅读'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 18),

            if (_exporting && _progress != null) ...[
              LinearProgressIndicator(
                value: _progress!.ratio > 0 ? _progress!.ratio : null,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 10),
              Text(
                _progress!.statusText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
                ),
              ),
              const SizedBox(height: 16),
            ],

            FilledButton.icon(
              onPressed: _exporting ? null : _startExport,
              icon: _exporting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(_exporting ? '正在导出中…' : '开始导出'),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _result!.success
                    ? (isDark ? const Color(0xFF1B2E24) : const Color(0xFFEAF5EF))
                    : (isDark ? const Color(0xFF331C1C) : const Color(0xFFFDECEC)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _result!.success
                      ? (isDark ? const Color(0xFF2B4D3C) : const Color(0xFFC7E6D4))
                      : (isDark ? const Color(0xFF5A2C2C) : const Color(0xFFF0C8C8)),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _result!.success
                            ? Icons.check_circle_rounded
                            : Icons.error_outline_rounded,
                        color: _result!.success
                            ? const Color(0xFF216B42)
                            : const Color(0xFFB33A32),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _result!.success ? '课件导出成功' : '导出失败',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: _result!.success
                              ? (isDark ? const Color(0xFF7BD49F) : const Color(0xFF1E643E))
                              : (isDark ? const Color(0xFFFFA49E) : const Color(0xFF9E2A23)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_result!.success) ...[
                    Text(
                      '已成功处理 ${_result!.fileCount} 页幻灯片并生成对应文件：',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? const Color(0xFFC3CFCA) : const Color(0xFF4A544F),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF141916) : Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isDark ? const Color(0xFF2B3630) : const Color(0xFFD6DDD8),
                        ),
                      ),
                      child: SelectableText(
                        _result!.path,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ] else ...[
                    Text(
                      _result!.errorMessage ?? '未知错误导致导出中断',
                      style: TextStyle(
                        fontSize: 13,
                        color: isDark ? const Color(0xFFFFA49E) : const Color(0xFF9E2A23),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (_result!.success) ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () async {
                        final ok = await FilePlatformHelper.openFile(
                          _result!.path,
                          mimeType: _result!.mimeType,
                        );
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('无法直接打开，请在文件管理器中查看')),
                          );
                        }
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 18),
                      label: const Text('打开文件'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: () async {
                        final ok = await FilePlatformHelper.shareFile(
                          _result!.path,
                          mimeType: _result!.mimeType,
                          title: widget.presentation.title,
                        );
                        if (!ok && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('无法调起系统分享')),
                          );
                        }
                      },
                      icon: const Icon(Icons.share_outlined, size: 18),
                      label: const Text('分享'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _copyPath(_result!.path),
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制路径'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => setState(() => _result = null),
                      child: const Text('重新选择'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _CachedSlideImage extends StatefulWidget {
  const _CachedSlideImage({
    required this.cache,
    required this.presentationId,
    required this.url,
    super.key,
  });

  final SlideCacheService cache;
  final String presentationId;
  final String url;

  @override
  State<_CachedSlideImage> createState() => _CachedSlideImageState();
}

class _CachedSlideImageState extends State<_CachedSlideImage> {
  File? _cachedFile;

  @override
  void initState() {
    super.initState();
    _checkCache();
  }

  Future<void> _checkCache() async {
    final file = await widget.cache.getCachedFile(
      widget.presentationId,
      widget.url,
    );
    if (mounted && file != null) {
      setState(() => _cachedFile = file);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cachedFile != null) {
      return Image.file(
        _cachedFile!,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _buildNetworkImage(),
      );
    }
    return _buildNetworkImage();
  }

  Widget _buildNetworkImage() {
    return Image.network(
      widget.url,
      fit: BoxFit.contain,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const Center(
          child: CircularProgressIndicator(color: Colors.white70),
        );
      },
      errorBuilder: (_, _, _) => const Icon(
        Icons.broken_image_outlined,
        size: 48,
        color: Colors.white54,
      ),
    );
  }
}

class _ConnectionDiagnosticSheet extends StatelessWidget {
  const _ConnectionDiagnosticSheet({
    required this.wsConnected,
    required this.authFailed,
    required this.latencyMs,
    required this.lastEventAt,
    required this.lessonId,
    required this.recentEvents,
    required this.onPing,
    required this.onReconnect,
    required this.onSyncAll,
  });

  final bool wsConnected;
  final bool authFailed;
  final int? latencyMs;
  final DateTime? lastEventAt;
  final String lessonId;
  final List<ClassroomEvent> recentEvents;
  final VoidCallback onPing;
  final VoidCallback onReconnect;
  final VoidCallback onSyncAll;

  String _formatLastEvent() {
    if (lastEventAt == null) return '暂无事件';
    final diff = DateTime.now().difference(lastEventAt!);
    if (diff.inSeconds < 5) return '刚刚';
    if (diff.inMinutes < 1) return '${diff.inSeconds} 秒前';
    return '${diff.inMinutes} 分钟前';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusColor = authFailed
        ? const Color(0xFFD93F34)
        : wsConnected
            ? const Color(0xFF216B42)
            : const Color(0xFFD97706);

    final statusLabel = authFailed
        ? '认证失效（需重新登录）'
        : wsConnected
            ? 'WebSocket 实时通道已连接'
            : '连接断开或重连中';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 28,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF38433E) : const Color(0xFFD1D5D2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.network_check_rounded, color: statusColor),
              const SizedBox(width: 10),
              const Text(
                '课堂连接诊断',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E2522) : const Color(0xFFF3F6F4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                _DiagRow(
                  label: '长连接状态',
                  value: statusLabel,
                  valueColor: statusColor,
                ),
                const Divider(height: 16),
                _DiagRow(
                  label: '信令往返延迟',
                  value: latencyMs != null ? '$latencyMs ms' : '待测速',
                ),
                const Divider(height: 16),
                _DiagRow(
                  label: '最近协议事件',
                  value: _formatLastEvent(),
                ),
                const Divider(height: 16),
                _DiagRow(
                  label: '当前课堂 ID',
                  value: lessonId,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (recentEvents.isNotEmpty) ...[
            Text(
              '最近收到的课堂消息 (${recentEvents.length})',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 140),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF141916) : const Color(0xFFF9FAF9),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isDark ? const Color(0xFF2B3630) : const Color(0xFFE0E5E2),
                ),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: recentEvents.length,
                itemBuilder: (_, idx) {
                  final ev = recentEvents[idx];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '[${ev.op}] ${ev.title} ${ev.description}'.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPing,
                  icon: const Icon(Icons.speed_rounded, size: 18),
                  label: const Text('心跳测速'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重连通道'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: onSyncAll,
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('强制重新同步全部课件与题目'),
          ),
        ],
      ),
    );
  }
}

class _DiagRow extends StatelessWidget {
  const _DiagRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: isDark ? const Color(0xFF9EABA4) : const Color(0xFF69716D),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: valueColor,
            ),
          ),
        ),
      ],
    );
  }
}
