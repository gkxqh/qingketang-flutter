Map<String, String> parseResponseCookies(
  Map<String, String> headers, [
  Map<String, String> existing = const {},
]) {
  final cookies = <String, String>{...existing};
  final raw = headers['set-cookie'] ?? headers['Set-Cookie'] ?? '';
  if (raw.isEmpty) return cookies;

  final parts = raw.split(RegExp(r',(?=[^;,]+=)'));
  for (final part in parts) {
    final pair = part.split(';').first.trim();
    final separator = pair.indexOf('=');
    if (separator <= 0) continue;
    final key = pair.substring(0, separator).trim();
    final value = pair.substring(separator + 1).trim();
    if (key.isEmpty ||
        const {
          'path',
          'domain',
          'expires',
          'max-age',
          'samesite',
          'secure',
          'httponly',
        }.contains(key.toLowerCase())) {
      continue;
    }
    cookies[key] = value;
  }
  return cookies;
}

Map<String, String> parseCookieString(String cookie) {
  final result = <String, String>{};
  for (final part in cookie.split(';')) {
    final trimmed = part.trim();
    final separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    result[trimmed.substring(0, separator).trim()] = trimmed
        .substring(separator + 1)
        .trim();
  }
  return result;
}

String joinCookies(Map<String, String> cookies) {
  return cookies.entries
      .where((entry) => entry.key.isNotEmpty)
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
}
