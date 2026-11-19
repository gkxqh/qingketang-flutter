import 'dart:async';

import '../models/answer_draft.dart';
import '../models/submission_job.dart';
import '../models/ykt_problem.dart';
import '../models/ykt_session.dart';
import 'auto_submit_store.dart';
import 'ykt_api_client.dart';

class SubmissionBusyException implements Exception {
  const SubmissionBusyException();
}

class SubmissionCoordinator {
  SubmissionCoordinator({
    required this.api,
    required this.store,
    required this.session,
    required this.lessonId,
    required this.bearerToken,
    required this.allowOvertime,
    this.onJobChanged,
  });

  final YktApiClient api;
  final AutoSubmitStore store;
  final YktSession session;
  final String lessonId;
  final String bearerToken;
  final bool allowOvertime;
  final Future<void> Function(SubmissionJob job)? onJobChanged;
  Future<void> _mutationTail = Future<void>.value();
  bool _runningDue = false;

  Future<SubmissionJob?> latestJob(String problemId) {
    return store.latestJobForProblem(lessonId: lessonId, problemId: problemId);
  }

  Future<SubmissionJob?> savePreselection(
    YktProblem problem,
    AnswerDraft draft,
  ) {
    return _serialize(() async {
      await store.saveDraft(draft);
      if (!await store.readEnabled() || !draft.hasAnswer) {
        return latestJob(problem.id);
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await latestJob(problem.id);
      if (existing != null &&
          (existing.state == SubmissionJobState.succeeded ||
              existing.state == SubmissionJobState.alreadyAnswered)) {
        return existing;
      }

      final delaySeconds = await store.readDelaySeconds();
      final published = problem.isPublished;
      final job = SubmissionJob(
        lessonId: lessonId,
        problemId: problem.id,
        problemType: problem.type,
        problemDt: problem.dt,
        title: problem.title,
        draft: draft,
        state: published
            ? SubmissionJobState.scheduled
            : SubmissionJobState.waitingPublish,
        trigger: SubmissionTrigger.automatic,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        scheduledAt: published ? now + delaySeconds * 1000 : 0,
        publishEpoch: published ? problem.dt : 0,
        deadlineRevision: problem.deadlineRevision,
      );
      await _replaceJob(existing, job);
      return job;
    });
  }

  Future<void> clearPreselection(String problemId) {
    return _serialize(() async {
      final job = await latestJob(problemId);
      if (job != null &&
          !job.isTerminal &&
          job.state != SubmissionJobState.submitting) {
        await _save(
          job.copyWith(
            state: SubmissionJobState.canceledByManual,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
            leaseToken: '',
            leaseUntil: 0,
          ),
        );
      }
      await store.clearDraft(problemId);
    });
  }

  Future<bool> cancelAutomaticSubmission(String problemId) {
    return _serialize(() async {
      final job = await latestJob(problemId);
      if (job == null ||
          job.isTerminal ||
          job.state == SubmissionJobState.submitting) {
        return false;
      }
      if (job.state != SubmissionJobState.waitingPublish &&
          job.state != SubmissionJobState.scheduled &&
          job.state != SubmissionJobState.retryRequired &&
          job.state != SubmissionJobState.retryableFailed &&
          job.state != SubmissionJobState.unknownOutcome) {
        return false;
      }
      await _save(
        job.copyWith(
          state: SubmissionJobState.canceledByManual,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          leaseToken: '',
          leaseUntil: 0,
        ),
      );
      return true;
    });
  }

  Future<SubmissionJob?> observePublish(
    YktProblem problem, {
    required bool live,
  }) {
    return _serialize(() async {
      if (!await store.readEnabled()) return latestJob(problem.id);
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await latestJob(problem.id);
      if (existing != null && existing.isTerminal) return existing;

      if (existing != null &&
          existing.state == SubmissionJobState.waitingPublish) {
        final delaySeconds = await store.readDelaySeconds();
        final promoted = existing.copyWith(
          problemDt: problem.dt,
          problemType: problem.type,
          title: problem.title,
          state: SubmissionJobState.scheduled,
          updatedAt: now,
          scheduledAt: now + delaySeconds * 1000,
          publishEpoch: problem.dt,
          deadlineRevision: problem.deadlineRevision,
        );
        await _replaceJob(existing, promoted);
        return promoted;
      }

      if (existing != null) return existing;
      if (!live) return null;

      final draft = await store.readDraft(problem.id);
      if (draft == null || !draft.hasAnswer) return null;
      final delaySeconds = await store.readDelaySeconds();
      final job = SubmissionJob(
        lessonId: lessonId,
        problemId: problem.id,
        problemType: problem.type,
        problemDt: problem.dt,
        title: problem.title,
        draft: draft,
        state: SubmissionJobState.scheduled,
        trigger: SubmissionTrigger.automatic,
        createdAt: now,
        updatedAt: now,
        scheduledAt: now + delaySeconds * 1000,
        publishEpoch: problem.dt,
        deadlineRevision: problem.deadlineRevision,
      );
      await _save(job);
      return job;
    });
  }

  Future<void> observeClose(String problemId) {
    return _serialize(() async {
      final job = await latestJob(problemId);
      if (job == null ||
          job.isTerminal ||
          job.state == SubmissionJobState.submitting ||
          job.state == SubmissionJobState.unknownOutcome) {
        return;
      }
      await _save(
        job.copyWith(
          state: SubmissionJobState.canceledByClose,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          leaseToken: '',
          leaseUntil: 0,
        ),
      );
    });
  }

  Future<void> observeLessonEnded() {
    return _serialize(() async {
      await store.cancelPendingJobsForLesson(
        lessonId,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  Future<List<SubmissionJob>> runDueJobs({required RuntimeLease lease}) async {
    if (_runningDue) return const [];
    _runningDue = true;
    try {
      return await _serialize(() async {
        if (!await store.ownsLease(lease)) return const [];
        final jobs = await store.readJobsForLesson(lessonId);
        final changed = <SubmissionJob>[];
        final now = DateTime.now().millisecondsSinceEpoch;
        final seenProblems = <String>{};
        for (final job in jobs) {
          if (!seenProblems.add(job.problemId)) continue;
          var candidate = job;
          if (candidate.state == SubmissionJobState.submitting &&
              candidate.leaseUntil <= now) {
            candidate = await _save(
              candidate.copyWith(
                state: SubmissionJobState.unknownOutcome,
                updatedAt: now,
                leaseToken: '',
                leaseUntil: 0,
                lastMessage: '提交过程中断，等待幂等复核',
              ),
            );
          }
          if (!_isDue(candidate, now)) continue;
          final currentLease = await store.renewOwner(lease);
          if (currentLease == null) break;
          final claimed = await _claim(candidate, currentLease);
          if (claimed == null) continue;
          final finished = await _execute(claimed, currentLease);
          changed.add(finished.job);
        }
        return changed;
      });
    } finally {
      _runningDue = false;
    }
  }

  Future<AnswerSubmitResult> submitManual({
    required YktProblem problem,
    required Object answer,
    required bool retry,
    required RuntimeLease lease,
  }) {
    return _serialize(() async {
      if (!await store.ownsLease(lease)) {
        return const AnswerSubmitResult(
          success: false,
          code: 401,
          message: '课堂连接所有权已失效，请回到课堂后重试',
        );
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final existing = await latestJob(problem.id);
      if (existing != null &&
          existing.state == SubmissionJobState.submitting &&
          existing.leaseUntil > now) {
        throw const SubmissionBusyException();
      }
      if (existing?.state == SubmissionJobState.succeeded) {
        return const AnswerSubmitResult(
          success: true,
          message: '该题已经提交，无需重复作答',
        );
      }
      if (existing?.state == SubmissionJobState.alreadyAnswered) {
        return const AnswerSubmitResult(
          success: false,
          code: 50028,
          message: '该题目已在其他客户端完成作答',
        );
      }

      final draft = AnswerDraft(
        problemId: problem.id,
        problemType: problem.type,
        selectedOptions: answer is List && problem.isChoice
            ? answer.map((item) => '$item').toList()
            : const [],
        fillAnswers: answer is List && problem.isFill
            ? answer.map((item) => '$item').toList()
            : const [],
        subjectiveContent: answer is Map ? '${answer['content'] ?? ''}' : '',
        images: answer is Map && answer['pics'] is List
            ? (answer['pics'] as List)
                  .whereType<Map>()
                  .map((item) => Map<String, dynamic>.from(item))
                  .toList()
            : const [],
        updatedAt: now,
      );
      final job = SubmissionJob(
        lessonId: lessonId,
        problemId: problem.id,
        problemType: problem.type,
        problemDt: problem.dt,
        title: problem.title,
        draft: draft,
        state: SubmissionJobState.submitting,
        trigger: SubmissionTrigger.manual,
        channel: retry ? SubmissionChannel.retry : SubmissionChannel.answer,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
        scheduledAt: now,
        attemptedAt: now,
        attemptCount: (existing?.attemptCount ?? 0) + 1,
        publishEpoch: problem.dt,
        deadlineRevision: problem.deadlineRevision,
        leaseToken: lease.token,
        leaseUntil: now + const Duration(seconds: 25).inMilliseconds,
      );
      await _replaceJob(existing, job);
      final executed = await _execute(job, lease);
      return executed.result;
    });
  }

  Future<SubmissionJob?> _claim(SubmissionJob job, RuntimeLease lease) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final channel = job.state == SubmissionJobState.retryRequired
        ? SubmissionChannel.retry
        : job.channel;
    final claimed = job.copyWith(
      state: SubmissionJobState.submitting,
      channel: channel,
      updatedAt: now,
      attemptedAt: now,
      attemptCount: job.attemptCount + 1,
      leaseToken: lease.token,
      leaseUntil: now + const Duration(seconds: 25).inMilliseconds,
    );
    await _save(claimed);
    return claimed;
  }

  Future<({SubmissionJob job, AnswerSubmitResult result})> _execute(
    SubmissionJob job,
    RuntimeLease lease,
  ) async {
    final answer = job.draft.answer;
    if (answer == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      const result = AnswerSubmitResult(
        success: false,
        code: -1,
        message: '作答内容为空或题型不支持',
      );
      final finished = await _finish(
        job,
        SubmissionJobState.terminalFailed,
        result,
        now,
      );
      return (job: finished, result: result);
    }

    final result = await api.submitAnswer(
      session: session,
      lessonId: lessonId,
      problemId: job.problemId,
      problemType: job.problemType,
      result: answer,
      problemDt: job.problemDt,
      retry: job.channel == SubmissionChannel.retry,
      bearerToken: bearerToken,
    );
    final now = DateTime.now().millisecondsSinceEpoch;

    if (result.success) {
      await store.clearDraft(job.problemId);
      final finished = await _finish(
        job,
        SubmissionJobState.succeeded,
        result,
        now,
      );
      return (job: finished, result: result);
    }
    if (result.isAlreadyAnswered) {
      await store.clearDraft(job.problemId);
      final finished = await _finish(
        job,
        SubmissionJobState.alreadyAnswered,
        result,
        now,
      );
      return (job: finished, result: result);
    }
    if (result.isAuthExpired) {
      final finished = await _finish(
        job,
        SubmissionJobState.authBlocked,
        result,
        now,
      );
      return (job: finished, result: result);
    }
    if (result.isClosed && job.channel == SubmissionChannel.answer) {
      final retryRequired = job.copyWith(
        state: SubmissionJobState.retryRequired,
        updatedAt: now,
        lastCode: result.code,
        lastMessage: result.message,
        leaseToken: '',
        leaseUntil: 0,
      );
      await _save(retryRequired);
      if (allowOvertime && await store.ownsLease(lease)) {
        final retryJob = retryRequired.copyWith(
          state: SubmissionJobState.submitting,
          channel: SubmissionChannel.retry,
          updatedAt: now,
          attemptedAt: now,
          attemptCount: retryRequired.attemptCount + 1,
          leaseToken: lease.token,
          leaseUntil: now + const Duration(seconds: 25).inMilliseconds,
        );
        await _save(retryJob);
        return _execute(retryJob, lease);
      }
      return (job: retryRequired, result: result);
    }
    if (result.isClosed) {
      final finished = await _finish(
        job,
        SubmissionJobState.terminalFailed,
        result,
        now,
      );
      return (job: finished, result: result);
    }
    if (result.isAmbiguous) {
      final finished = await _finish(
        job,
        SubmissionJobState.unknownOutcome,
        result,
        now,
      );
      return (job: finished, result: result);
    }

    final retryable = const {500, 502, 503, 504}.contains(result.code);
    final finished = await _finish(
      job,
      retryable
          ? SubmissionJobState.retryableFailed
          : SubmissionJobState.terminalFailed,
      result,
      now,
    );
    return (job: finished, result: result);
  }

  Future<SubmissionJob> _finish(
    SubmissionJob job,
    SubmissionJobState state,
    AnswerSubmitResult result,
    int now,
  ) async {
    return _save(
      job.copyWith(
        state: state,
        updatedAt: now,
        lastCode: result.code,
        lastMessage: result.message,
        leaseToken: '',
        leaseUntil: 0,
      ),
    );
  }

  bool _isDue(SubmissionJob job, int now) {
    if (job.state == SubmissionJobState.scheduled) {
      return job.scheduledAt <= now;
    }
    if (job.state == SubmissionJobState.retryRequired) {
      return allowOvertime;
    }
    if (job.state == SubmissionJobState.retryableFailed ||
        job.state == SubmissionJobState.unknownOutcome) {
      if (job.attemptCount >= 2) return false;
      final backoff = Duration(seconds: 5 * job.attemptCount).inMilliseconds;
      return job.updatedAt + backoff <= now;
    }
    return false;
  }

  Future<void> _replaceJob(SubmissionJob? previous, SubmissionJob next) async {
    await _save(next);
    if (previous != null && previous.key != next.key) {
      await store.deleteJob(previous);
    }
  }

  Future<SubmissionJob> _save(SubmissionJob job) async {
    await store.saveJob(job);
    await onJobChanged?.call(job);
    return job;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _mutationTail = _mutationTail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stack) {
        completer.completeError(error, stack);
      }
    });
    return completer.future;
  }
}
