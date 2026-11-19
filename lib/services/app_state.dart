import 'dart:async';

import 'package:flutter/material.dart';

import '../models/ykt_homework.dart';
import '../models/ykt_lesson.dart';
import '../models/ykt_session.dart';
import '../models/submission_job.dart';
import 'auto_submit_store.dart';
import 'file_platform_helper.dart';
import 'ykt_api_client.dart';
import 'ykt_session_store.dart';

class AppState extends ChangeNotifier {
  AppState({
    YktApiClient? apiClient,
    YktSessionStore? sessionStore,
    AutoSubmitStore? autoSubmitStore,
  }) : api = apiClient ?? YktApiClient(),
       store = sessionStore ?? YktSessionStore(),
       autoSubmitStore = autoSubmitStore ?? AutoSubmitStore();

  final YktApiClient api;
  final YktSessionStore store;
  final AutoSubmitStore autoSubmitStore;

  YktSession? session;
  YktServer selectedServer = YktServer.yuketang;
  AutoCheckinMode autoCheckinMode = AutoCheckinMode.immediate;
  bool allowOvertime = true;
  bool autoSubmitEnabled = false;
  int autoSubmitDelaySeconds = 3;
  bool privacyAgreed = false;
  bool hideHomeProfile = false;
  bool homeNoticeEnabled = true;
  ThemeMode themeMode = ThemeMode.system;
  String? exportDirectory;
  bool developerModeEnabled = false;
  bool showLessonIdEntry = false;
  String homeNickname = '';
  String homeAvatarPath = '';
  bool loading = false;
  bool initialized = false;
  bool sessionExpired = false;
  SessionValidation sessionStatus = SessionValidation.unknown;
  String? error;
  List<YktLesson> lessons = const [];
  List<YktHomeworkTask> homeworks = const [];
  Set<String> locallyDoneHomeworkIds = const {};
  bool homeworksLoading = false;
  String? homeworksError;
  DateTime? homeworksUpdatedAt;

  int get pendingHomeworkCount => homeworks
      .where((t) => t.status == HomeworkStatus.unsubmitted && !locallyDoneHomeworkIds.contains(t.id))
      .length;

  int get urgentHomeworkCount => homeworks
      .where((t) => t.isUrgent && !locallyDoneHomeworkIds.contains(t.id))
      .length;

  String get displayName => session?.name ?? '未登录';
  String get homeDisplayName =>
      homeNickname.trim().isNotEmpty ? homeNickname.trim() : displayName;
  bool get hasCustomHomeProfile =>
      homeNickname.trim().isNotEmpty || homeAvatarPath.isNotEmpty;
  String get school =>
      session?.school.isNotEmpty == true ? session!.school : '雨课堂';
  bool get isLoggedIn => session != null;

  Future<void> initialize() async {
    selectedServer = await store.readServer();
    autoCheckinMode = await store.readAutoCheckinMode();
    allowOvertime = await store.readAllowOvertime();
    autoSubmitEnabled = await autoSubmitStore.readEnabled();
    autoSubmitDelaySeconds = await autoSubmitStore.readDelaySeconds();
    privacyAgreed = await store.readPrivacyAgreement();
    hideHomeProfile = await store.readHideHomeProfile();
    homeNickname = await store.readHomeNickname();
    homeAvatarPath = await store.readHomeAvatarPath();
    homeNoticeEnabled = await store.readHomeNoticeEnabled();
    themeMode = await store.readThemeMode();
    exportDirectory = await store.readExportDirectory();
    developerModeEnabled = await store.readDeveloperMode();
    showLessonIdEntry = await store.readShowLessonIdEntry();
    homeworks = await store.readHomeworkTasks();
    locallyDoneHomeworkIds = await store.readLocallyDoneHomeworkIds();
    session = await store.readSession();
    initialized = true;
    notifyListeners();
    if (session != null) {
      unawaited(refreshLessons());
      unawaited(refreshHomeworks());
    }
  }

  Future<void> setSession(YktSession value) async {
    session = value;
    sessionExpired = false;
    sessionStatus = SessionValidation.valid;
    selectedServer = value.server;
    await store.saveSession(value);
    await store.saveServer(value.server);
    notifyListeners();
    await refreshLessons();
    unawaited(refreshHomeworks());
  }

  Future<void> logout() async {
    await store.clearSession();
    session = null;
    sessionExpired = false;
    sessionStatus = SessionValidation.invalid;
    lessons = const [];
    homeworks = const [];
    homeworksError = null;
    error = null;
    notifyListeners();
  }

  Future<void> refreshHomeworks() async {
    final current = session;
    if (current == null) return;
    homeworksLoading = true;
    homeworksError = null;
    notifyListeners();

    try {
      final tasks = await api.fetchAllHomeworkTasks(current);
      homeworks = tasks;
      homeworksUpdatedAt = DateTime.now();
      await store.saveHomeworkTasks(tasks);
    } on YktApiException catch (exception) {
      homeworksError = exception.message;
      if (exception.code == 401 ||
          exception.code == 50000 ||
          exception.code == 10001) {
        await _expireSession(exception.message);
      }
    } catch (e) {
      homeworksError = e.toString();
    } finally {
      homeworksLoading = false;
      notifyListeners();
    }
  }

  Future<void> toggleHomeworkLocalDone(String id) async {
    final next = Set<String>.from(locallyDoneHomeworkIds);
    if (next.contains(id)) {
      next.remove(id);
    } else {
      next.add(id);
    }
    locallyDoneHomeworkIds = next;
    await store.saveLocallyDoneHomeworkIds(next);
    notifyListeners();
  }

  Future<void> updateServer(YktServer value) async {
    selectedServer = value;
    await store.saveServer(value);
    notifyListeners();
  }

  Future<void> updateAutoCheckinMode(AutoCheckinMode value) async {
    autoCheckinMode = value;
    await store.saveAutoCheckinMode(value);
    notifyListeners();
  }

  Future<void> updateAllowOvertime(bool value) async {
    allowOvertime = value;
    await store.saveAllowOvertime(value);
    notifyListeners();
  }

  Future<void> updateAutoSubmitEnabled(bool value) async {
    autoSubmitEnabled = value;
    await autoSubmitStore.saveEnabled(value);
    if (!value) {
      await autoSubmitStore.cancelPendingJobs(
        state: SubmissionJobState.canceledByManual,
      );
    }
    notifyListeners();
  }

  Future<void> updateAutoSubmitDelay(int seconds) async {
    autoSubmitDelaySeconds = seconds.clamp(0, 60);
    await autoSubmitStore.saveDelaySeconds(autoSubmitDelaySeconds);
    notifyListeners();
  }

  Future<void> setPrivacyAgreed(bool value) async {
    privacyAgreed = value;
    await store.savePrivacyAgreement(value);
    notifyListeners();
  }

  Future<void> updateHideHomeProfile(bool value) async {
    hideHomeProfile = value;
    await store.saveHideHomeProfile(value);
    notifyListeners();
  }

  Future<void> updateHomeNickname(String value) async {
    homeNickname = value.trim();
    await store.saveHomeNickname(homeNickname);
    notifyListeners();
  }

  Future<void> updateHomeAvatarPath(String value) async {
    homeAvatarPath = value;
    await store.saveHomeAvatarPath(value);
    notifyListeners();
  }

  Future<void> resetHomeProfile() async {
    homeNickname = '';
    homeAvatarPath = '';
    await store.saveHomeNickname('');
    await store.saveHomeAvatarPath('');
    notifyListeners();
  }

  Future<void> dismissHomeNotice() async {
    homeNoticeEnabled = false;
    await store.saveHomeNoticeEnabled(false);
    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode value) async {
    themeMode = value;
    await store.saveThemeMode(value);
    notifyListeners();
  }

  Future<String> getEffectiveExportDirectory() async {
    if (exportDirectory != null && exportDirectory!.trim().isNotEmpty) {
      return exportDirectory!.trim();
    }
    return FilePlatformHelper.getDefaultExportDirectory();
  }

  Future<void> updateExportDirectory(String? path) async {
    final trimmed = path?.trim();
    exportDirectory = (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
    await store.saveExportDirectory(exportDirectory);
    notifyListeners();
  }

  Future<void> updateDeveloperMode(bool value) async {
    developerModeEnabled = value;
    await store.saveDeveloperMode(value);
    notifyListeners();
  }

  Future<void> updateShowLessonIdEntry(bool value) async {
    showLessonIdEntry = value;
    await store.saveShowLessonIdEntry(value);
    notifyListeners();
  }

  Future<void> refreshLessons({bool runAutoCheckin = true}) async {
    final current = session;
    if (current == null) {
      lessons = const [];
      notifyListeners();
      return;
    }
    loading = true;
    error = null;
    notifyListeners();
    try {
      final validation = await api.validateSession(current);
      sessionStatus = validation;
      if (validation == SessionValidation.invalid) {
        await _expireSession('雨课堂登录状态已过期');
        return;
      }
      if (validation == SessionValidation.unknown) {
        error = '暂时无法确认雨课堂登录状态，请检查网络';
        return;
      }
      final fetched = await api.fetchOnLesson(current);
      final tokens = await store.readLessonTokens();
      lessons = mergeLessonCheckinStatus(
        fetched,
        previous: lessons,
        tokens: tokens,
      );
      if (runAutoCheckin &&
          autoCheckinMode == AutoCheckinMode.immediate &&
          fetched.isNotEmpty) {
        for (var index = 0; index < lessons.length; index++) {
          final lesson = lessons[index];
          if (lesson.requiresDynamicQr) continue;
          final result = await checkIn(lesson, notifyLoading: false);
          if (result.requiresDynamicQr) {
            lessons = [
              for (final item in lessons)
                item.id == lesson.id
                    ? item.copyWith(requiresDynamicQr: true)
                    : item,
            ];
          } else if (result.success) {
            lessons = [
              for (final item in lessons)
                item.id == lesson.id ? item.copyWith(isCheckedIn: true) : item,
            ];
          }
        }
      }
    } on YktApiException catch (exception) {
      error = exception.message;
      if (exception.code == 401 ||
          exception.code == 50000 ||
          exception.code == 10001) {
        await _expireSession(exception.message);
      }
    } catch (exception) {
      error = exception.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<CheckinResult> checkIn(
    YktLesson lesson, {
    bool notifyLoading = true,
  }) async {
    final current = session;
    if (current == null) {
      return const CheckinResult(code: 401, message: '未登录雨课堂');
    }
    final tokens = await store.readLessonTokens();
    final cached = tokens[lesson.id];
    if (cached != null && cached.isFresh) {
      final info = await api.fetchLessonInfo(
        session: current,
        lessonId: lesson.id,
      );
      return CheckinResult(
        code: 0,
        message: '复用有效课堂凭据',
        lessonToken: cached.lessonToken,
        bearerToken: cached.bearerToken,
        activePresentationId: cached.activePresentationId,
        presentations: info.presentations,
      );
    }
    if (notifyLoading) notifyListeners();
    try {
      final result = await api.checkIn(session: current, lesson: lesson);
      if (result.code == 401 || result.code == 50000 || result.code == 10001) {
        await _expireSession(result.message);
        return result;
      }
      if (result.success) {
        await store.saveLessonToken(
          YktLessonToken(
            lessonId: lesson.id,
            lessonToken: result.lessonToken,
            bearerToken: result.bearerToken,
            activePresentationId: result.activePresentationId,
            presentationList: result.presentations
                .map((item) => item.id)
                .toList(),
            savedAt: DateTime.now(),
          ),
        );
        lessons = [
          for (final item in lessons)
            item.id == lesson.id ? item.copyWith(isCheckedIn: true) : item,
        ];
      } else if (result.requiresDynamicQr) {
        lessons = [
          for (final item in lessons)
            item.id == lesson.id
                ? item.copyWith(requiresDynamicQr: true)
                : item,
        ];
      }
      notifyListeners();
      return result;
    } catch (exception) {
      error = exception.toString();
      notifyListeners();
      return CheckinResult(code: -1, message: error ?? '签到失败');
    }
  }

  Future<YktLessonToken?> lessonToken(String lessonId) async {
    final tokens = await store.readLessonTokens();
    final token = tokens[lessonId];
    return token != null && token.isFresh ? token : null;
  }

  Future<void> _expireSession(String message) async {
    await store.clearSession();
    session = null;
    sessionExpired = true;
    sessionStatus = SessionValidation.invalid;
    lessons = const [];
    error = message;
    notifyListeners();
  }

  @override
  void dispose() {
    api.dispose();
    super.dispose();
  }
}

List<YktLesson> mergeLessonCheckinStatus(
  List<YktLesson> fetched, {
  required List<YktLesson> previous,
  required Map<String, YktLessonToken> tokens,
}) {
  final previousById = {for (final lesson in previous) lesson.id: lesson};
  return [
    for (final lesson in fetched)
      lesson.copyWith(
        isCheckedIn:
            lesson.isCheckedIn ||
            (previousById[lesson.id]?.isCheckedIn ?? false) ||
            (tokens[lesson.id]?.isFresh ?? false),
        requiresDynamicQr:
            lesson.requiresDynamicQr ||
            (previousById[lesson.id]?.requiresDynamicQr ?? false),
      ),
  ];
}
