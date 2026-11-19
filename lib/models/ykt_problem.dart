enum ProblemSource { embedded, liveEvent, timeline }

enum ProblemBoundary {
  embeddedOnly,
  publishedActive,
  teacherClosed,
  lessonEnded,
}

enum ProblemPhase {
  embeddedOnly,
  publishedActive,
  overdue,
  teacherClosed,
  lessonEnded,
}

enum ProblemAnswerState {
  unknown,
  unanswered,
  submittedByMe,
  answeredElsewhere,
}

class YktProblem {
  YktProblem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.options,
    required this.dt,
    required this.limit,
    required this.serverNow,
    required ProblemBoundary initialBoundary,
    required ProblemAnswerState initialAnswerState,
    this.source = ProblemSource.liveEvent,
    int receivedAt = 0,
    this.userAnswer,
    this.presentationId = '',
    this.page = 1,
    this.slideIndex = 0,
    this.coverUrl = '',
    this.extend = 0,
    this.raw = const {},
  }) : _boundary = initialBoundary,
       _answerState = initialAnswerState,
       receivedAt = receivedAt <= 0
           ? DateTime.now().millisecondsSinceEpoch
           : receivedAt;

  final String id;
  final int type;
  final String title;
  final String body;
  final List<ProblemOption> options;
  final int dt;
  int limit;
  final int serverNow;
  final ProblemSource source;
  final int receivedAt;
  ProblemBoundary _boundary;
  ProblemAnswerState _answerState;
  Object? userAnswer;
  final String presentationId;
  final int page;
  final int slideIndex;
  final String coverUrl;
  int extend;
  int deadlineRevision = 0;
  int closeRevision = 0;
  final Map<String, dynamic> raw;

  bool get isChoice => type == 1 || type == 2 || type == 3;
  bool get isFill => type == 4;
  bool get isSubjective => type == 5;
  bool get isMultiple => type == 2 || type == 3;
  ProblemBoundary get boundary => _boundary;
  ProblemAnswerState get answerState => _answerState;
  bool get isPublished => _boundary != ProblemBoundary.embeddedOnly;
  bool get isClosed =>
      _boundary == ProblemBoundary.teacherClosed ||
      _boundary == ProblemBoundary.lessonEnded;
  bool get isSubmitted =>
      _answerState == ProblemAnswerState.submittedByMe ||
      _answerState == ProblemAnswerState.answeredElsewhere;

  ProblemPhase get phase {
    if (_boundary == ProblemBoundary.embeddedOnly) {
      return ProblemPhase.embeddedOnly;
    }
    if (_boundary == ProblemBoundary.lessonEnded) {
      return ProblemPhase.lessonEnded;
    }
    if (_boundary == ProblemBoundary.teacherClosed) {
      return ProblemPhase.teacherClosed;
    }
    return isOverdue ? ProblemPhase.overdue : ProblemPhase.publishedActive;
  }

  int get remainingSeconds {
    if (limit <= 0) return 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - receivedAt;
    final estimatedServerNow = serverNow + elapsed;
    final deadline = dt + limit * 1000;
    return ((deadline - estimatedServerNow) / 1000).floor().clamp(
      0,
      24 * 60 * 60,
    );
  }

  bool get isOverdue => limit > 0 && remainingSeconds <= 0;

  void markPublished() {
    if (_boundary == ProblemBoundary.embeddedOnly) {
      _boundary = ProblemBoundary.publishedActive;
      deadlineRevision++;
    }
  }

  void markClosed() {
    if (_boundary == ProblemBoundary.lessonEnded) return;
    _boundary = ProblemBoundary.teacherClosed;
    closeRevision++;
  }

  void markLessonEnded() {
    _boundary = ProblemBoundary.lessonEnded;
    closeRevision++;
  }

  void markAnswerState(ProblemAnswerState state) {
    _answerState = state;
  }

  int extendBy(int seconds, {int? absoluteLimit}) {
    final previousLimit = limit;
    final absolute = absoluteLimit != null && absoluteLimit > previousLimit
        ? absoluteLimit
        : 0;
    var extension = seconds;
    if (extension <= 0 && absolute > 0) {
      extension = absolute - previousLimit;
    }
    if (extension <= 0) extension = 30;

    final incrementalLimit = previousLimit + extension;
    final updatedLimit = absolute > incrementalLimit
        ? absolute
        : incrementalLimit;
    extension = updatedLimit - previousLimit;
    limit = updatedLimit;
    extend += extension;
    if (_boundary == ProblemBoundary.teacherClosed) {
      _boundary = ProblemBoundary.publishedActive;
      closeRevision++;
    }
    deadlineRevision++;
    return extension;
  }

  YktProblem copyWith({
    int? limit,
    int? serverNow,
    ProblemBoundary? boundary,
    ProblemAnswerState? answerState,
    ProblemSource? source,
    int? receivedAt,
    Object? userAnswer,
    String? presentationId,
    int? page,
    int? slideIndex,
    String? coverUrl,
    int? extend,
    int? deadlineRevision,
    int? closeRevision,
  }) {
    final copy = YktProblem(
      id: id,
      type: type,
      title: title,
      body: body,
      options: options,
      dt: dt,
      limit: limit ?? this.limit,
      serverNow: serverNow ?? this.serverNow,
      initialBoundary: boundary ?? _boundary,
      initialAnswerState: answerState ?? _answerState,
      source: source ?? this.source,
      receivedAt: receivedAt ?? this.receivedAt,
      userAnswer: userAnswer ?? this.userAnswer,
      presentationId: presentationId ?? this.presentationId,
      page: page ?? this.page,
      slideIndex: slideIndex ?? this.slideIndex,
      coverUrl: coverUrl ?? this.coverUrl,
      extend: extend ?? this.extend,
      raw: raw,
    );
    copy.deadlineRevision = deadlineRevision ?? this.deadlineRevision;
    copy.closeRevision = closeRevision ?? this.closeRevision;
    return copy;
  }

  factory YktProblem.fromJson(
    Map<String, dynamic> json, {
    bool published = true,
    ProblemSource source = ProblemSource.liveEvent,
    int receivedAt = 0,
    String presentationId = '',
    int page = 1,
    int slideIndex = 0,
    String coverUrl = '',
  }) {
    final problem = json['problem'] is Map
        ? Map<String, dynamic>.from(json['problem'] as Map)
        : json;
    final type = _problemType(problem);
    final rawOptions =
        problem['bullets'] ??
        problem['Bullets'] ??
        problem['options'] ??
        problem['Options'] ??
        [];
    final options = type == 1 || type == 2 || type == 3
        ? (rawOptions is List && rawOptions.isNotEmpty
              ? rawOptions
                    .asMap()
                    .entries
                    .map(
                      (entry) => ProblemOption.fromRaw(entry.value, entry.key),
                    )
                    .toList()
              : const [
                  ProblemOption(label: 'A', text: ''),
                  ProblemOption(label: 'B', text: ''),
                  ProblemOption(label: 'C', text: ''),
                  ProblemOption(label: 'D', text: ''),
                ])
        : const <ProblemOption>[];
    final dt = _milliseconds(
      problem['dt'] ?? problem['time'] ?? DateTime.now().millisecondsSinceEpoch,
    );
    final serverNow = _milliseconds(
      problem['serverNow'] ??
          problem['now'] ??
          DateTime.now().millisecondsSinceEpoch,
    );
    final explicitAnswer =
        problem['user_answer'] ??
        problem['my_answer'] ??
        (published ? problem['result'] ?? problem['answer'] : null);
    final explicitlySubmitted =
        problem['isSubmitted'] == true ||
        problem['isCompleted'] == true ||
        problem['answered'] == true ||
        problem['isAnswered'] == true ||
        problem['is_answered'] == true ||
        problem['has_answered'] == true;
    final hasAnswer = explicitAnswer != null && '$explicitAnswer'.isNotEmpty;
    final boundary = problem['isClosed'] == true
        ? ProblemBoundary.teacherClosed
        : published
        ? ProblemBoundary.publishedActive
        : ProblemBoundary.embeddedOnly;
    return YktProblem(
      id: '${problem['prob'] ?? problem['problemid'] ?? problem['problemId'] ?? problem['id'] ?? ''}'
          .replaceFirst(RegExp(r'^prob-'), ''),
      type: type,
      title: '${problem['title'] ?? problem['Title'] ?? _defaultTitle(type)}',
      body:
          '${problem['body'] ?? problem['Body'] ?? problem['content'] ?? problem['Content'] ?? problem['stem'] ?? problem['desc'] ?? ''}',
      options: options,
      dt: dt,
      limit:
          int.tryParse('${problem['limit'] ?? problem['timelimit'] ?? 0}') ?? 0,
      serverNow: serverNow,
      initialBoundary: boundary,
      initialAnswerState: explicitlySubmitted || hasAnswer
          ? ProblemAnswerState.submittedByMe
          : ProblemAnswerState.unanswered,
      source: source,
      receivedAt: receivedAt,
      userAnswer: explicitAnswer,
      presentationId: presentationId,
      page: page,
      slideIndex: slideIndex,
      coverUrl: coverUrl,
      extend: int.tryParse('${problem['extend'] ?? 0}') ?? 0,
      raw: problem,
    );
  }

  static int _problemType(Map<String, dynamic> problem) {
    final type =
        problem['problemType'] ?? problem['problemtype'] ?? problem['type'];
    final text = '${problem['title'] ?? ''} ${problem['body'] ?? ''}';
    final numeric = int.tryParse('$type');
    if (numeric != null) return numeric;
    if ('$type'.toLowerCase().contains('subject') ||
        text.contains('主观') ||
        text.contains('简答')) {
      return 5;
    }
    if ('$type'.toLowerCase().contains('fill') || text.contains('填空')) {
      return 4;
    }
    if (text.contains('多选')) return 2;
    if (text.contains('投票')) return 3;
    return 1;
  }

  static int _milliseconds(Object? value) {
    final number = int.tryParse('${value ?? 0}') ?? 0;
    return number > 0 && number < 100000000000 ? number * 1000 : number;
  }

  static String _defaultTitle(int type) => switch (type) {
    2 => '多项选择题',
    3 => '随堂投票',
    4 => '随堂填空题',
    5 => '主观简答题',
    _ => '单项选择题',
  };
}

class ProblemOption {
  const ProblemOption({required this.label, required this.text});

  final String label;
  final String text;

  factory ProblemOption.fromRaw(Object? raw, int index) {
    if (raw is String) {
      return ProblemOption(label: String.fromCharCode(65 + index), text: raw);
    }
    if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return ProblemOption(
        label:
            '${map['key'] ?? map['label'] ?? String.fromCharCode(65 + index)}',
        text: '${map['value'] ?? map['content'] ?? map['text'] ?? ''}',
      );
    }
    return ProblemOption(label: String.fromCharCode(65 + index), text: '$raw');
  }
}

class UploadedAnswerImage {
  const UploadedAnswerImage({required this.pic, required this.thumb});

  final String pic;
  final String thumb;

  Map<String, dynamic> toJson() => {'pic': pic, 'thumb': thumb};
}

class AnswerSubmitResult {
  const AnswerSubmitResult({
    required this.success,
    required this.message,
    this.code = 0,
  });

  final bool success;
  final String message;
  final int code;

  bool get isAlreadyAnswered => code == 50028;
  bool get isAuthExpired => code == 401 || code == 50000 || code == 10001;
  bool get isClosed =>
      code == 50026 ||
      code == 500 ||
      message.toUpperCase().contains('CLOSED') ||
      message.toUpperCase().contains('FINISHED') ||
      message.contains('已收题');
  bool get isAmbiguous =>
      code == -1 || message.contains('网络异常') || message.contains('网络连接');
}
