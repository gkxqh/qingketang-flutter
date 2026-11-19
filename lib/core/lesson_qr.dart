import 'dart:convert';

const _lessonIdPattern = r'^\d{10,25}$';
const _labeledIdPattern =
    r'(?:lessonId|lesson_id|lessonid|classroomId|classroom_id|activityId|activity_id)'
    r'\s*[=:]\s*["'
    "'"
    r']?(\d{10,25})';
const _pathIdPattern =
    r'/(?:lesson|classroom|activity|join)/[^/?#]*?(\d{10,25})(?:[/?#]|$)';

String? parseLessonIdFromQr(String rawValue) {
  final raw = rawValue.trim();
  if (RegExp(_lessonIdPattern).hasMatch(raw)) return raw;

  final directMatch = RegExp(
    _labeledIdPattern,
    caseSensitive: false,
  ).firstMatch(raw);
  if (directMatch != null) return directMatch.group(1);

  final decoded = _tryDecode(raw);
  if (decoded != null && decoded != raw) {
    final nested = parseLessonIdFromQr(decoded);
    if (nested != null) return nested;
  }

  final uri = Uri.tryParse(decoded ?? raw);
  if (uri != null) {
    for (final entry in uri.queryParameters.entries) {
      final key = entry.key.toLowerCase();
      if (const {
            'lessonid',
            'lesson_id',
            'classroomid',
            'classroom_id',
            'activityid',
            'activity_id',
          }.contains(key) &&
          RegExp(_lessonIdPattern).hasMatch(entry.value)) {
        return entry.value;
      }
    }
    for (final value in uri.queryParameters.values) {
      if (RegExp(_lessonIdPattern).hasMatch(value)) return value;
    }
    final pathMatch = RegExp(
      _pathIdPattern,
      caseSensitive: false,
    ).firstMatch(uri.path);
    if (pathMatch != null) return pathMatch.group(1);
    for (final segment in uri.pathSegments.reversed) {
      if (RegExp(_lessonIdPattern).hasMatch(segment)) return segment;
    }
    if (uri.fragment.isNotEmpty) {
      return parseLessonIdFromQr(uri.fragment);
    }
  }

  if (raw.startsWith('{') && raw.endsWith('}')) {
    try {
      final data = jsonDecode(raw);
      if (data is Map) {
        for (final key in [
          'lessonId',
          'lesson_id',
          'lessonid',
          'classroomId',
          'activityId',
        ]) {
          final value = '${data[key] ?? ''}';
          if (RegExp(_lessonIdPattern).hasMatch(value)) return value;
        }
      }
    } catch (_) {
      // Ignore malformed JSON QR values.
    }
  }
  return null;
}

String? _tryDecode(String value) {
  try {
    final decoded = Uri.decodeComponent(value);
    return decoded == value ? null : decoded;
  } catch (_) {
    return null;
  }
}
