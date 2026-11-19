class YktLesson {
  const YktLesson({
    required this.id,
    required this.name,
    required this.teacher,
    required this.classroom,
    required this.startTime,
    required this.raw,
    this.requiresDynamicQr = false,
    this.isCheckedIn = false,
  });

  final String id;
  final String name;
  final String teacher;
  final String classroom;
  final int startTime;
  final Map<String, dynamic> raw;
  final bool requiresDynamicQr;
  final bool isCheckedIn;

  factory YktLesson.fromJson(Map<String, dynamic> json) {
    final id = '${json['lessonId'] ?? json['id'] ?? json['lesson_id'] ?? ''}';
    final rawStart =
        json['startTime'] ??
        json['start_time'] ??
        json['beginTime'] ??
        json['createTime'] ??
        json['createdAt'];
    return YktLesson(
      id: id,
      name: '${json['name'] ?? json['courseName'] ?? json['title'] ?? '随堂课堂'}',
      teacher: '${json['teacher'] ?? json['teacherName'] ?? ''}',
      classroom:
          '${json['classroomName'] ?? json['className'] ?? json['classroom'] ?? ''}',
      startTime: _timestamp(rawStart) ?? _validTimestamp(int.tryParse(id)) ?? 0,
      raw: json,
    );
  }

  YktLesson copyWith({bool? requiresDynamicQr, bool? isCheckedIn}) {
    return YktLesson(
      id: id,
      name: name,
      teacher: teacher,
      classroom: classroom,
      startTime: startTime,
      raw: raw,
      requiresDynamicQr: requiresDynamicQr ?? this.requiresDynamicQr,
      isCheckedIn: isCheckedIn ?? this.isCheckedIn,
    );
  }

  static int? _timestamp(Object? value) {
    if (value == null) return null;
    if (value is num) {
      final number = value.toInt();
      return _validTimestamp(number < 100000000000 ? number * 1000 : number);
    }
    final parsed = DateTime.tryParse('$value');
    return _validTimestamp(parsed?.millisecondsSinceEpoch);
  }

  static int? _validTimestamp(int? value) {
    if (value == null) return null;
    // Rain Classroom lesson IDs are snowflake-like values, not timestamps.
    const min = 946684800000; // 2000-01-01
    const max = 4102444800000; // 2100-01-01
    return value >= min && value <= max ? value : null;
  }
}

class PresentationSummary {
  const PresentationSummary({
    required this.id,
    required this.title,
    required this.slideCount,
  });

  final String id;
  final String title;
  final int slideCount;

  factory PresentationSummary.fromJson(Map<String, dynamic> json) {
    return PresentationSummary(
      id: '${json['id'] ?? json['presentationID'] ?? json['presentation_id'] ?? ''}',
      title: '${json['Title'] ?? json['title'] ?? '课堂课件'}',
      slideCount:
          (json['slides'] as List?)?.length ??
          int.tryParse('${json['slide_count'] ?? 0}') ??
          0,
    );
  }
}

class CheckinResult {
  const CheckinResult({
    required this.code,
    required this.message,
    this.lessonToken = '',
    this.bearerToken = '',
    this.activePresentationId = '',
    this.presentations = const [],
  });

  final int code;
  final String message;
  final String lessonToken;
  final String bearerToken;
  final String activePresentationId;
  final List<PresentationSummary> presentations;

  bool get success => code == 0;
  bool get requiresDynamicQr => code == 50070;
}
