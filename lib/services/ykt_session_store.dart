import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/background_lesson_context.dart';
import '../models/ykt_homework.dart';
import '../models/ykt_session.dart';

class YktSessionStore {
  YktSessionStore({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _sessionKey = 'ykt_user_session_v1';
  static const _historyKey = 'ykt_history_accounts_v1';
  static const _lessonTokensKey = 'ykt_lesson_tokens_v1';
  static const _serverKey = 'ykt_active_server_v1';
  static const _autoCheckinKey = 'ykt_auto_checkin_mode';
  static const _overtimeKey = 'ykt_allow_overtime_submit';
  static const _privacyKey = 'has_agreed_privacy_policy';
  static const _backgroundContextKey = 'ykt_background_lesson_context_v1';
  static const _hideHomeProfileKey = 'ykt_hide_home_profile_v1';
  static const _homeNicknameKey = 'ykt_home_nickname_v1';
  static const _homeAvatarKey = 'ykt_home_avatar_v1';
  static const _homeNoticeEnabledKey = 'ykt_home_notice_enabled_v1';
  static const _themeModeKey = 'ykt_theme_mode_v1';
  static const _exportDirectoryKey = 'ykt_export_directory_v1';
  static const _homeworksCacheKey = 'ykt_homeworks_cache_v1';
  static const _locallyDoneHomeworksKey = 'ykt_locally_done_homeworks_v1';
  static const _developerModeKey = 'ykt_developer_mode_v1';
  static const _showLessonIdEntryKey = 'ykt_show_lesson_id_entry_v1';

  final FlutterSecureStorage _secureStorage;

  Future<YktSession?> readSession() async {
    try {
      final raw = await _secureStorage.read(key: _sessionKey);
      if (raw == null || raw.isEmpty) return null;
      return YktSession.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveSession(YktSession session) async {
    await _secureStorage.write(
      key: _sessionKey,
      value: jsonEncode(session.toJson()),
    );
    final history = await readHistory();
    history.removeWhere((item) => item.userId == session.userId);
    history.insert(0, session);
    if (history.length > 5) history.removeRange(5, history.length);
    await _secureStorage.write(
      key: _historyKey,
      value: jsonEncode(history.map((item) => item.toJson()).toList()),
    );
  }

  Future<List<YktSession>> readHistory() async {
    try {
      final raw = await _secureStorage.read(key: _historyKey);
      if (raw == null || raw.isEmpty) return [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((item) => YktSession.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> clearSession() async {
    await _secureStorage.delete(key: _sessionKey);
    await _secureStorage.delete(key: _lessonTokensKey);
  }

  Future<Map<String, YktLessonToken>> readLessonTokens() async {
    try {
      final raw = await _secureStorage.read(key: _lessonTokensKey);
      if (raw == null || raw.isEmpty) return {};
      final map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return map.map(
        (key, value) => MapEntry(
          key,
          YktLessonToken.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> saveLessonToken(YktLessonToken token) async {
    final current = await readLessonTokens();
    current.removeWhere((key, value) => !value.isFresh);
    current[token.lessonId] = token;
    if (current.length > 2) {
      final entries = current.entries.toList()
        ..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
      current
        ..clear()
        ..addEntries(entries.take(2));
    }
    await _secureStorage.write(
      key: _lessonTokensKey,
      value: jsonEncode(
        current.map((key, value) => MapEntry(key, value.toJson())),
      ),
    );
  }

  Future<void> saveBackgroundContext(BackgroundLessonContext context) async {
    await _secureStorage.write(
      key: _backgroundContextKey,
      value: jsonEncode(context.toJson()),
    );
  }

  Future<BackgroundLessonContext?> readBackgroundContext() async {
    try {
      final raw = await _secureStorage.read(key: _backgroundContextKey);
      if (raw == null || raw.isEmpty) return null;
      return BackgroundLessonContext.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> clearBackgroundContext() async {
    await _secureStorage.delete(key: _backgroundContextKey);
  }

  Future<YktServer> readServer() async {
    final prefs = await SharedPreferences.getInstance();
    return YktServer.fromId(prefs.getString(_serverKey));
  }

  Future<void> saveServer(YktServer server) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, server.id);
  }

  Future<AutoCheckinMode> readAutoCheckinMode() async {
    final prefs = await SharedPreferences.getInstance();
    return AutoCheckinMode.fromId(prefs.getString(_autoCheckinKey));
  }

  Future<void> saveAutoCheckinMode(AutoCheckinMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_autoCheckinKey, mode.id);
  }

  Future<bool> readAllowOvertime() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_overtimeKey) ?? true;
  }

  Future<void> saveAllowOvertime(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_overtimeKey, value);
  }

  Future<bool> readPrivacyAgreement() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_privacyKey) ?? false;
  }

  Future<void> savePrivacyAgreement(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_privacyKey, value);
  }

  Future<bool> readHideHomeProfile() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hideHomeProfileKey) ?? false;
  }

  Future<void> saveHideHomeProfile(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hideHomeProfileKey, value);
  }

  Future<String> readHomeNickname() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_homeNicknameKey) ?? '';
  }

  Future<void> saveHomeNickname(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final nickname = value.trim();
    if (nickname.isEmpty) {
      await prefs.remove(_homeNicknameKey);
    } else {
      await prefs.setString(_homeNicknameKey, nickname);
    }
  }

  Future<String> readHomeAvatarPath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_homeAvatarKey) ?? '';
  }

  Future<void> saveHomeAvatarPath(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value.isEmpty) {
      await prefs.remove(_homeAvatarKey);
    } else {
      await prefs.setString(_homeAvatarKey, value);
    }
  }

  Future<bool> readHomeNoticeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_homeNoticeEnabledKey) ?? true;
  }

  Future<void> saveHomeNoticeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_homeNoticeEnabledKey, value);
  }

  Future<ThemeMode> readThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_themeModeKey);
    return switch (value) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    final value = switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };
    await prefs.setString(_themeModeKey, value);
  }

  Future<String?> readExportDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_exportDirectoryKey);
    return (value != null && value.trim().isNotEmpty) ? value.trim() : null;
  }

  Future<void> saveExportDirectory(String? path) async {
    final prefs = await SharedPreferences.getInstance();
    if (path == null || path.trim().isEmpty) {
      await prefs.remove(_exportDirectoryKey);
    } else {
      await prefs.setString(_exportDirectoryKey, path.trim());
    }
  }

  Future<bool> readDeveloperMode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_developerModeKey) ?? false;
  }

  Future<void> saveDeveloperMode(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_developerModeKey, value);
  }

  Future<bool> readShowLessonIdEntry() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_showLessonIdEntryKey) ?? false;
  }

  Future<void> saveShowLessonIdEntry(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_showLessonIdEntryKey, value);
  }

  Future<List<YktHomeworkTask>> readHomeworkTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_homeworksCacheKey);
      if (raw == null || raw.isEmpty) return const [];
      return (jsonDecode(raw) as List)
          .whereType<Map>()
          .map((e) => YktHomeworkTask.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveHomeworkTasks(List<YktHomeworkTask> tasks) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _homeworksCacheKey,
      jsonEncode(tasks.map((e) => e.toJson()).toList()),
    );
  }

  Future<Set<String>> readLocallyDoneHomeworkIds() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_locallyDoneHomeworksKey) ?? const []).toSet();
  }

  Future<void> saveLocallyDoneHomeworkIds(Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_locallyDoneHomeworksKey, ids.toList());
  }
}

enum AutoCheckinMode {
  immediate(id: 'immediate', label: '开课立即签到'),
  ask(id: 'ask', label: '签到前询问'),
  notify(id: 'notify', label: '仅横幅提醒'),
  off(id: 'off', label: '关闭自动签到');

  const AutoCheckinMode({required this.id, required this.label});

  final String id;
  final String label;

  static AutoCheckinMode fromId(String? id) {
    return AutoCheckinMode.values.firstWhere(
      (mode) => mode.id == id,
      orElse: () => AutoCheckinMode.immediate,
    );
  }
}
