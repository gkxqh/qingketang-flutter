import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/answer_draft.dart';
import '../models/submission_job.dart';

class AutoSubmitStore {
  static const _enabledKey = 'ykt_auto_submit_enabled';
  static const _delayKey = 'ykt_auto_submit_delay_seconds';
  static const _legacyDraftsKey = 'ykt_answer_drafts_v1';
  static const _draftPrefix = 'ykt_answer_draft_v2:';
  static const _jobPrefix = 'ykt_submission_job_v2:';
  static const _leaseKey = 'ykt_runtime_lease_v2';
  static const _logKey = 'ykt_auto_submit_log_v1';
  static final Random _random = Random.secure();

  Future<bool> readEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? false;
  }

  Future<void> saveEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  Future<int> readDelaySeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_delayKey) ?? 3;
  }

  Future<void> saveDelaySeconds(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_delayKey, value.clamp(0, 60));
  }

  Future<Map<String, AnswerDraft>> readDrafts() async {
    final prefs = await SharedPreferences.getInstance();
    final drafts = <String, AnswerDraft>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_draftPrefix)) continue;
      final decoded = _decodeMap(prefs.getString(key));
      if (decoded == null) continue;
      final draft = AnswerDraft.fromJson(decoded);
      if (draft.problemId.isNotEmpty) drafts[draft.problemId] = draft;
    }

    final legacy = _decodeMap(prefs.getString(_legacyDraftsKey));
    if (legacy != null) {
      for (final entry in legacy.entries) {
        if (drafts.containsKey(entry.key) || entry.value is! Map) continue;
        drafts[entry.key] = AnswerDraft.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }
    return drafts;
  }

  Future<AnswerDraft?> readDraft(String problemId) async {
    final prefs = await SharedPreferences.getInstance();
    final current = _decodeMap(prefs.getString(_draftKey(problemId)));
    if (current != null) return AnswerDraft.fromJson(current);

    final legacy = _decodeMap(prefs.getString(_legacyDraftsKey));
    final value = legacy?[problemId];
    if (value is Map) {
      return AnswerDraft.fromJson(Map<String, dynamic>.from(value));
    }
    return null;
  }

  Future<void> saveDraft(AnswerDraft draft) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _draftKey(draft.problemId);
    if (draft.hasAnswer) {
      await prefs.setString(key, jsonEncode(draft.toJson()));
    } else {
      await prefs.remove(key);
    }
    await _removeLegacyDraft(prefs, draft.problemId);
  }

  Future<void> clearDraft(String problemId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_draftKey(problemId));
    await _removeLegacyDraft(prefs, problemId);
  }

  Future<List<SubmissionJob>> readJobs({String? lessonId}) async {
    final prefs = await SharedPreferences.getInstance();
    final jobs = <SubmissionJob>[];
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_jobPrefix)) continue;
      final decoded = _decodeMap(prefs.getString(key));
      if (decoded == null) continue;
      final job = SubmissionJob.fromJson(decoded);
      if (job.problemId.isEmpty) continue;
      if (lessonId != null && job.lessonId != lessonId) continue;
      jobs.add(job);
    }
    jobs.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return jobs;
  }

  Future<List<SubmissionJob>> readJobsForLesson(String lessonId) {
    return readJobs(lessonId: lessonId);
  }

  Future<SubmissionJob?> latestJobForProblem({
    required String lessonId,
    required String problemId,
  }) async {
    final jobs = await readJobs(lessonId: lessonId);
    for (final job in jobs) {
      if (job.problemId == problemId) return job;
    }
    return null;
  }

  Future<void> saveJob(SubmissionJob job) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_jobPrefix${job.key}', jsonEncode(job.toJson()));
  }

  Future<void> deleteJob(SubmissionJob job) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_jobPrefix${job.key}');
  }

  Future<void> deleteJobsForProblem({
    required String lessonId,
    required String problemId,
  }) async {
    final jobs = await readJobsForLesson(lessonId);
    for (final job in jobs) {
      if (job.problemId == problemId) await deleteJob(job);
    }
  }

  Future<void> cancelPendingJobsForLesson(
    String lessonId, {
    required int updatedAt,
  }) async {
    final jobs = await readJobsForLesson(lessonId);
    for (final job in jobs) {
      if (job.isTerminal || job.state == SubmissionJobState.submitting) {
        continue;
      }
      await saveJob(
        job.copyWith(
          state: SubmissionJobState.canceledByLessonEnd,
          updatedAt: updatedAt,
        ),
      );
    }
  }

  Future<void> cancelPendingJobs({required SubmissionJobState state}) async {
    final jobs = await readJobs();
    final updatedAt = DateTime.now().millisecondsSinceEpoch;
    for (final job in jobs) {
      if (job.isTerminal || job.state == SubmissionJobState.submitting) {
        continue;
      }
      await saveJob(
        job.copyWith(
          state: state,
          updatedAt: updatedAt,
          leaseToken: '',
          leaseUntil: 0,
        ),
      );
    }
  }

  Future<RuntimeLease?> readLease() async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = _decodeMap(prefs.getString(_leaseKey));
    return decoded == null ? null : RuntimeLease.fromJson(decoded);
  }

  Future<RuntimeLease> acquireOwner({
    required RuntimeOwner owner,
    required String lessonId,
    Duration ttl = const Duration(seconds: 45),
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final prefs = await SharedPreferences.getInstance();
    final decoded = _decodeMap(prefs.getString(_leaseKey));
    final existing = decoded == null ? null : RuntimeLease.fromJson(decoded);
    if (existing != null &&
        existing.isActiveAt(now) &&
        existing.lessonId == lessonId &&
        existing.owner != owner) {
      return existing;
    }

    final lease = RuntimeLease(
      lessonId: lessonId,
      owner: owner,
      token: _newToken(),
      generation: (existing?.generation ?? 0) + 1,
      expiresAt: now + ttl.inMilliseconds,
    );
    await prefs.setString(_leaseKey, jsonEncode(lease.toJson()));
    return lease;
  }

  Future<void> releaseOwner(RuntimeLease lease) async {
    final prefs = await SharedPreferences.getInstance();
    final decoded = _decodeMap(prefs.getString(_leaseKey));
    if (decoded == null) return;
    final current = RuntimeLease.fromJson(decoded);
    if (current.token != lease.token) return;
    await prefs.remove(_leaseKey);
  }

  Future<bool> ownsLease(RuntimeLease lease) async {
    final current = await readLease();
    final now = DateTime.now().millisecondsSinceEpoch;
    return current != null &&
        current.token == lease.token &&
        current.owner == lease.owner &&
        current.lessonId == lease.lessonId &&
        current.isActiveAt(now);
  }

  Future<RuntimeLease?> renewOwner(RuntimeLease lease) async {
    if (!await ownsLease(lease)) return null;
    final renewed = RuntimeLease(
      lessonId: lease.lessonId,
      owner: lease.owner,
      token: lease.token,
      generation: lease.generation,
      expiresAt: DateTime.now()
          .add(const Duration(seconds: 45))
          .millisecondsSinceEpoch,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_leaseKey, jsonEncode(renewed.toJson()));
    return renewed;
  }

  Future<void> appendLog(String message) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getStringList(_logKey) ?? <String>[];
    current.add('${DateTime.now().toIso8601String()} $message');
    final trimmed = current.length > 80
        ? current.sublist(current.length - 80)
        : current;
    await prefs.setStringList(_logKey, trimmed);
  }

  Future<List<String>> readLogs() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_logKey) ?? <String>[];
  }

  String _draftKey(String problemId) =>
      '$_draftPrefix${Uri.encodeComponent(problemId)}';

  Future<void> _removeLegacyDraft(
    SharedPreferences prefs,
    String problemId,
  ) async {
    final legacy = _decodeMap(prefs.getString(_legacyDraftsKey));
    if (legacy == null || !legacy.containsKey(problemId)) return;
    legacy.remove(problemId);
    if (legacy.isEmpty) {
      await prefs.remove(_legacyDraftsKey);
    } else {
      await prefs.setString(_legacyDraftsKey, jsonEncode(legacy));
    }
  }

  Map<String, dynamic>? _decodeMap(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  String _newToken() {
    final now = DateTime.now().microsecondsSinceEpoch;
    final suffix = _random.nextInt(0x7FFFFFFF).toRadixString(16);
    return '$now-$suffix';
  }
}
