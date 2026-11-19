import 'answer_draft.dart';

enum SubmissionJobState {
  waitingPublish,
  scheduled,
  submitting,
  unknownOutcome,
  retryRequired,
  retryableFailed,
  terminalFailed,
  succeeded,
  alreadyAnswered,
  canceledByManual,
  canceledByClose,
  canceledByLessonEnd,
  authBlocked,
}

enum SubmissionTrigger { automatic, manual }

enum SubmissionChannel { answer, retry }

class SubmissionJob {
  const SubmissionJob({
    required this.lessonId,
    required this.problemId,
    required this.problemType,
    required this.problemDt,
    required this.title,
    required this.draft,
    required this.state,
    required this.trigger,
    this.channel = SubmissionChannel.answer,
    required this.createdAt,
    required this.updatedAt,
    this.scheduledAt = 0,
    this.attemptedAt = 0,
    this.attemptCount = 0,
    this.publishEpoch = 0,
    this.deadlineRevision = 0,
    this.lastCode = 0,
    this.lastMessage = '',
    this.leaseToken = '',
    this.leaseUntil = 0,
  });

  final String lessonId;
  final String problemId;
  final int problemType;
  final int problemDt;
  final String title;
  final AnswerDraft draft;
  final SubmissionJobState state;
  final SubmissionTrigger trigger;
  final SubmissionChannel channel;
  final int createdAt;
  final int updatedAt;
  final int scheduledAt;
  final int attemptedAt;
  final int attemptCount;
  final int publishEpoch;
  final int deadlineRevision;
  final int lastCode;
  final String lastMessage;
  final String leaseToken;
  final int leaseUntil;

  String get key {
    final epoch = publishEpoch == 0 ? 'waiting' : '$publishEpoch';
    return '${Uri.encodeComponent(lessonId)}:${Uri.encodeComponent(problemId)}:$epoch';
  }

  bool get isTerminal => const {
    SubmissionJobState.succeeded,
    SubmissionJobState.alreadyAnswered,
    SubmissionJobState.canceledByManual,
    SubmissionJobState.canceledByClose,
    SubmissionJobState.canceledByLessonEnd,
    SubmissionJobState.terminalFailed,
    SubmissionJobState.authBlocked,
  }.contains(state);

  bool get canBeClaimed =>
      state == SubmissionJobState.scheduled ||
      state == SubmissionJobState.retryableFailed;

  SubmissionJob copyWith({
    String? lessonId,
    String? problemId,
    int? problemType,
    int? problemDt,
    String? title,
    AnswerDraft? draft,
    SubmissionJobState? state,
    SubmissionTrigger? trigger,
    SubmissionChannel? channel,
    int? createdAt,
    int? updatedAt,
    int? scheduledAt,
    int? attemptedAt,
    int? attemptCount,
    int? publishEpoch,
    int? deadlineRevision,
    int? lastCode,
    String? lastMessage,
    String? leaseToken,
    int? leaseUntil,
  }) {
    return SubmissionJob(
      lessonId: lessonId ?? this.lessonId,
      problemId: problemId ?? this.problemId,
      problemType: problemType ?? this.problemType,
      problemDt: problemDt ?? this.problemDt,
      title: title ?? this.title,
      draft: draft ?? this.draft,
      state: state ?? this.state,
      trigger: trigger ?? this.trigger,
      channel: channel ?? this.channel,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      attemptedAt: attemptedAt ?? this.attemptedAt,
      attemptCount: attemptCount ?? this.attemptCount,
      publishEpoch: publishEpoch ?? this.publishEpoch,
      deadlineRevision: deadlineRevision ?? this.deadlineRevision,
      lastCode: lastCode ?? this.lastCode,
      lastMessage: lastMessage ?? this.lastMessage,
      leaseToken: leaseToken ?? this.leaseToken,
      leaseUntil: leaseUntil ?? this.leaseUntil,
    );
  }

  Map<String, dynamic> toJson() => {
    'lesson_id': lessonId,
    'problem_id': problemId,
    'problem_type': problemType,
    'problem_dt': problemDt,
    'title': title,
    'draft': draft.toJson(),
    'state': state.name,
    'trigger': trigger.name,
    'channel': channel.name,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'scheduled_at': scheduledAt,
    'attempted_at': attemptedAt,
    'attempt_count': attemptCount,
    'publish_epoch': publishEpoch,
    'deadline_revision': deadlineRevision,
    'last_code': lastCode,
    'last_message': lastMessage,
    'lease_token': leaseToken,
    'lease_until': leaseUntil,
  };

  factory SubmissionJob.fromJson(Map<String, dynamic> json) {
    return SubmissionJob(
      lessonId: '${json['lesson_id'] ?? ''}',
      problemId: '${json['problem_id'] ?? ''}',
      problemType: int.tryParse('${json['problem_type'] ?? 1}') ?? 1,
      problemDt: int.tryParse('${json['problem_dt'] ?? 0}') ?? 0,
      title: '${json['title'] ?? ''}',
      draft: AnswerDraft.fromJson(
        Map<String, dynamic>.from(json['draft'] as Map? ?? const {}),
      ),
      state: _enumByName(
        SubmissionJobState.values,
        '${json['state'] ?? ''}',
        SubmissionJobState.waitingPublish,
      ),
      trigger: _enumByName(
        SubmissionTrigger.values,
        '${json['trigger'] ?? ''}',
        SubmissionTrigger.automatic,
      ),
      channel: _enumByName(
        SubmissionChannel.values,
        '${json['channel'] ?? ''}',
        SubmissionChannel.answer,
      ),
      createdAt: int.tryParse('${json['created_at'] ?? 0}') ?? 0,
      updatedAt: int.tryParse('${json['updated_at'] ?? 0}') ?? 0,
      scheduledAt: int.tryParse('${json['scheduled_at'] ?? 0}') ?? 0,
      attemptedAt: int.tryParse('${json['attempted_at'] ?? 0}') ?? 0,
      attemptCount: int.tryParse('${json['attempt_count'] ?? 0}') ?? 0,
      publishEpoch: int.tryParse('${json['publish_epoch'] ?? 0}') ?? 0,
      deadlineRevision: int.tryParse('${json['deadline_revision'] ?? 0}') ?? 0,
      lastCode: int.tryParse('${json['last_code'] ?? 0}') ?? 0,
      lastMessage: '${json['last_message'] ?? ''}',
      leaseToken: '${json['lease_token'] ?? ''}',
      leaseUntil: int.tryParse('${json['lease_until'] ?? 0}') ?? 0,
    );
  }
}

enum RuntimeOwner { none, foreground, background }

class RuntimeLease {
  const RuntimeLease({
    required this.lessonId,
    required this.owner,
    required this.token,
    required this.generation,
    required this.expiresAt,
  });

  final String lessonId;
  final RuntimeOwner owner;
  final String token;
  final int generation;
  final int expiresAt;

  bool isActiveAt(int milliseconds) =>
      owner != RuntimeOwner.none &&
      token.isNotEmpty &&
      expiresAt > milliseconds;

  Map<String, dynamic> toJson() => {
    'lesson_id': lessonId,
    'owner': owner.name,
    'token': token,
    'generation': generation,
    'expires_at': expiresAt,
  };

  factory RuntimeLease.fromJson(Map<String, dynamic> json) {
    return RuntimeLease(
      lessonId: '${json['lesson_id'] ?? ''}',
      owner: _enumByName(
        RuntimeOwner.values,
        '${json['owner'] ?? ''}',
        RuntimeOwner.none,
      ),
      token: '${json['token'] ?? ''}',
      generation: int.tryParse('${json['generation'] ?? 0}') ?? 0,
      expiresAt: int.tryParse('${json['expires_at'] ?? 0}') ?? 0,
    );
  }
}

T _enumByName<T extends Enum>(List<T> values, String name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
