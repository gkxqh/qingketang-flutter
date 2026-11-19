class ClassroomEvent {
  const ClassroomEvent({
    required this.op,
    required this.payload,
    required this.receivedAt,
  });

  final String op;
  final Map<String, dynamic> payload;
  final DateTime receivedAt;

  String get title => switch (op) {
    'unlockproblem' || 'problemon' => '老师发布随堂习题',
    'extendtime' => '答题时间已延长',
    'problemfinished' || 'closeproblem' || 'problemoff' => '老师已收题',
    'callroll' || 'randompick' || 'callpaused' => '课堂随机点名',
    'notification' => '课堂通知',
    'showpresentation' || 'presentationstart' => '开始放映课件',
    'slidenav' || 'slide' || 'slideshow' => '老师翻页',
    'redpack' || 'bonus' => '课堂红包',
    'rush' || 'quickanswer' => '随堂抢答',
    'danmu' => '课堂弹幕',
    _ => '课堂动态',
  };

  String get description {
    return '${_firstValue(const ['text', 'content', 'desc', 'title', 'message']) ?? title}';
  }

  int? get slideIndex {
    for (final scope in _scopes) {
      for (final key in ['slideindex', 'slideIndex', 'page', 'si', 'index']) {
        final value = scope[key];
        final parsed = int.tryParse('$value');
        if (parsed != null && parsed >= 0 && parsed < 1000) {
          // Rain Classroom event fields are page numbers (1-based), while
          // PageView and the presentation array are zero-based.
          return parsed > 0 ? parsed - 1 : 0;
        }
      }
    }
    return null;
  }

  String get presentationId {
    for (final scope in _scopes) {
      final value =
          scope['presentation'] ??
          scope['presentationid'] ??
          scope['presentationId'] ??
          scope['pres'];
      if (value != null && '$value'.isNotEmpty) return '$value';
    }
    return '';
  }

  Map<String, dynamic>? get problem {
    for (final scope in _scopes) {
      final nested = scope['problem'];
      if (nested is Map) return Map<String, dynamic>.from(nested);
      if (scope['prob'] != null ||
          scope['problemid'] != null ||
          scope['problemId'] != null) {
        return scope;
      }
    }
    return null;
  }

  Iterable<Map<String, dynamic>> get _scopes sync* {
    yield payload;
    for (final key in ['slide', 'event', 'data', 'problem']) {
      final value = payload[key];
      if (value is Map) {
        yield Map<String, dynamic>.from(value);
      }
    }
  }

  Object? _firstValue(List<String> keys) {
    for (final scope in _scopes) {
      for (final key in keys) {
        final value = scope[key];
        if (value != null && '$value'.isNotEmpty) return value;
      }
    }
    return null;
  }
}
