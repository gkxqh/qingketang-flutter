enum HomeworkStatus {
  unsubmitted('未提交'),
  submitted('已提交'),
  graded('已批改'),
  overdue('已逾期');

  const HomeworkStatus(this.label);
  final String label;
}

class YktCourse {
  const YktCourse({
    required this.classroomId,
    required this.courseId,
    required this.courseName,
    required this.teacherName,
    this.term = '',
  });

  final String classroomId;
  final String courseId;
  final String courseName;
  final String teacherName;
  final String term;

  factory YktCourse.fromJson(Map<String, dynamic> json) {
    final teacher = json['teacher'];
    var teacherName = '';
    if (teacher is Map) {
      teacherName = '${teacher['name'] ?? ''}';
    } else if (json['teacher_name'] != null) {
      teacherName = '${json['teacher_name']}';
    }
    final courseObj = json['course'];
    var courseObjName = '';
    if (courseObj is Map) {
      courseObjName = '${courseObj['name'] ?? courseObj['course_name'] ?? ''}'.trim();
    }
    final rawCourseName = '${json['course_name'] ?? json['courseName'] ?? ''}'.trim();
    final rawClassName = '${json['classroom_name'] ?? json['classroomName'] ?? json['name'] ?? ''}'.trim();
    final resolvedCourseName = courseObjName.isNotEmpty
        ? courseObjName
        : rawCourseName.isNotEmpty
            ? rawCourseName
            : rawClassName.isNotEmpty
                ? rawClassName
                : '未命名课程';
    return YktCourse(
      classroomId: '${json['classroom_id'] ?? json['classroomId'] ?? json['id'] ?? ''}',
      courseId: '${json['course_id'] ?? json['courseId'] ?? ''}',
      courseName: resolvedCourseName,
      teacherName: teacherName,
      term: '${json['term'] ?? json['semester'] ?? ''}',
    );
  }
}

class YktHomeworkTask {
  const YktHomeworkTask({
    required this.id,
    required this.classroomId,
    required this.courseName,
    required this.title,
    required this.status,
    this.startTime,
    this.deadline,
    this.allowOverdueSubmit = false,
    this.overdueScoreRate,
    this.score,
    this.totalScore,
    this.webUrl,
    this.isExam = false,
  });

  final String id;
  final String classroomId;
  final String courseName;
  final String title;
  final HomeworkStatus status;
  final DateTime? startTime;
  final DateTime? deadline;
  final bool allowOverdueSubmit;
  final double? overdueScoreRate;
  final double? score;
  final double? totalScore;
  final String? webUrl;
  final bool isExam;

  bool get isCompleted =>
      status == HomeworkStatus.submitted || status == HomeworkStatus.graded;

  Duration? get remainingDuration {
    if (deadline == null) return null;
    return deadline!.difference(DateTime.now());
  }

  /// 是否在 24 小时内截止且未提交
  bool get isUrgent {
    if (isCompleted || status == HomeworkStatus.overdue) return false;
    final rem = remainingDuration;
    return rem != null && !rem.isNegative && rem.inHours < 24;
  }

  /// 是否在 2 小时内截止且未提交
  bool get isCritical {
    if (isCompleted || status == HomeworkStatus.overdue) return false;
    final rem = remainingDuration;
    return rem != null && !rem.isNegative && rem.inHours < 2;
  }

  String get remainingText {
    final rem = remainingDuration;
    if (rem == null) return '无明确截止时间';
    if (rem.isNegative) {
      final overdueDays = rem.inDays.abs();
      if (overdueDays > 0) return '已逾期 $overdueDays 天';
      final overdueHours = rem.inHours.abs();
      if (overdueHours > 0) return '已逾期 $overdueHours 小时';
      return '已截止';
    }
    if (rem.inDays > 0) {
      return '剩 ${rem.inDays} 天 ${rem.inHours % 24} 小时';
    }
    if (rem.inHours > 0) {
      return '剩 ${rem.inHours} 小时 ${rem.inMinutes % 60} 分';
    }
    if (rem.inMinutes > 0) {
      return '剩 ${rem.inMinutes} 分钟';
    }
    return '即将截止';
  }

  String get overdueRuleText {
    if (!allowOverdueSubmit) return '逾期不可补交';
    if (overdueScoreRate != null && overdueScoreRate! > 0 && overdueScoreRate! < 1) {
      final percent = (overdueScoreRate! * 100).round();
      return '允许补交 · 按 $percent% 计分';
    }
    return '允许逾期补交';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'classroomId': classroomId,
        'courseName': courseName,
        'title': title,
        'status': status.name,
        'startTime': startTime?.millisecondsSinceEpoch,
        'deadline': deadline?.millisecondsSinceEpoch,
        'allowOverdueSubmit': allowOverdueSubmit,
        'overdueScoreRate': overdueScoreRate,
        'score': score,
        'totalScore': totalScore,
        'webUrl': webUrl,
        'isExam': isExam,
      };

  factory YktHomeworkTask.fromJson(Map<String, dynamic> json) {
    final statusName = '${json['status'] ?? 'unsubmitted'}';
    final status = HomeworkStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => HomeworkStatus.unsubmitted,
    );
    final startMs = json['startTime'] as int?;
    final deadlineMs = json['deadline'] as int?;
    return YktHomeworkTask(
      id: '${json['id'] ?? ''}',
      classroomId: '${json['classroomId'] ?? ''}',
      courseName: '${json['courseName'] ?? ''}',
      title: '${json['title'] ?? ''}',
      status: status,
      startTime: startMs != null ? DateTime.fromMillisecondsSinceEpoch(startMs) : null,
      deadline: deadlineMs != null ? DateTime.fromMillisecondsSinceEpoch(deadlineMs) : null,
      allowOverdueSubmit: json['allowOverdueSubmit'] == true,
      overdueScoreRate: (json['overdueScoreRate'] as num?)?.toDouble(),
      score: (json['score'] as num?)?.toDouble(),
      totalScore: (json['totalScore'] as num?)?.toDouble(),
      webUrl: json['webUrl'] as String?,
      isExam: json['isExam'] == true,
    );
  }
}
