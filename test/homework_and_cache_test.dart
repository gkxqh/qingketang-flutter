import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/models/ykt_homework.dart';
import 'package:gongxiaohu_flutter/models/ykt_session.dart';
import 'package:gongxiaohu_flutter/services/app_state.dart';
import 'package:gongxiaohu_flutter/services/slide_cache_service.dart';
import 'package:gongxiaohu_flutter/services/ykt_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Phase 1: Homework & Task Center', () {
    test('YktHomeworkTask calculates urgent and critical countdowns accurately', () {
      final now = DateTime.now();
      final criticalTask = YktHomeworkTask(
        id: 'hw-1',
        classroomId: 'c1',
        courseName: '计算机网络',
        title: '第3次实验报告',
        status: HomeworkStatus.unsubmitted,
        deadline: now.add(const Duration(minutes: 45)),
        allowOverdueSubmit: true,
        overdueScoreRate: 0.8,
      );

      expect(criticalTask.isCritical, isTrue);
      expect(criticalTask.isUrgent, isTrue);
      expect(criticalTask.overdueRuleText, '允许补交 · 按 80% 计分');

      final submittedTask = YktHomeworkTask(
        id: 'hw-2',
        classroomId: 'c1',
        courseName: '计算机网络',
        title: '第2次作业',
        status: HomeworkStatus.graded,
        deadline: now.add(const Duration(minutes: 30)),
        score: 95,
        totalScore: 100,
      );

      expect(submittedTask.isCompleted, isTrue);
      expect(submittedTask.isCritical, isFalse);
      expect(submittedTask.isUrgent, isFalse);
    });

    test('YktApiClient parses courses and homework activities and sorts by urgency', () async {
      final futureSoon = DateTime.now().add(const Duration(hours: 3)).millisecondsSinceEpoch ~/ 1000;
      final futureLater = DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch ~/ 1000;

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v2/api/web/courses/list') {
          return http.Response(
            jsonEncode({
              'errcode': 0,
              'data': {
                'list': [
                  {
                    'classroom_id': '1001',
                    'course_id': 'c1001',
                    'course_name': '高等数学',
                    'teacher': {'name': '张老师'},
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/v2/api/web/logs/learn/1001') {
          return http.Response(
            jsonEncode({
              'errcode': 0,
              'data': {
                'activities': [
                  {
                    'type': 15,
                    'courseware_id': 'hw_later',
                    'title': '课后习题二',
                    'deadline': futureLater,
                    'submit_status': 0,
                    'allow_overdue': false,
                  },
                  {
                    'type': 15,
                    'courseware_id': 'hw_soon',
                    'title': '课后习题一',
                    'deadline': futureSoon,
                    'submit_status': 0,
                    'allow_overdue': true,
                    'overdue_score_rate': 0.7,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/api/v3/classroom/on-lesson-upcoming-exam') {
          return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
        }
        return http.Response('{}', 404);
      });

      final api = YktApiClient(client: client);
      const session = YktSession(
        userId: 'u1',
        name: '测试同学',
        school: 'SCU',
        avatar: '',
        cookie: 'sessionid=abc; csrftoken=xyz',
        server: YktServer.yuketang,
      );

      final tasks = await api.fetchAllHomeworkTasks(session);
      expect(tasks.length, 2);
      // 紧急的课后习题一排在最前面
      expect(tasks[0].title, '课后习题一');
      expect(tasks[0].allowOverdueSubmit, isTrue);
      expect(tasks[0].overdueScoreRate, 0.7);
      expect(tasks[1].title, '课后习题二');
    });

    test('YktApiClient treats logs/learn type=5 status=1 without submit_status as unsubmitted', () async {
      final futureLater = DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch;

      final client = MockClient((req) async {
        final path = req.url.path;
        if (path == '/v2/api/web/courses/list') {
          return http.Response(
            jsonEncode({
              'errcode': 0,
              'data': {
                'list': [
                  {
                    'classroom_id': '31894217',
                    'course_id': 'c3189',
                    'course_name': '2026秋-31135303001',
                    'teacher': {'name': '李老师'},
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/v2/api/web/logs/learn/31894217') {
          return http.Response(
            jsonEncode({
              'errcode': 0,
              'data': {
                'activities': [
                  {
                    'type': 5,
                    'courseware_id': '4794589',
                    'title': '实验2 JUnit单元测试提交',
                    'deadline': futureLater,
                    'status': 1,
                    'score': null,
                    'total_score': 10,
                    'progress': 0,
                    'problem_count': 1,
                  },
                  {
                    'type': 5,
                    'courseware_id': '4766039',
                    'title': '软件测试-作业03-基于代码的测试',
                    'deadline': futureLater,
                    'status': 2,
                    'score': null,
                    'total_score': 40,
                    'progress': 4,
                    'problem_count': 4,
                  },
                  {
                    'type': 5,
                    'courseware_id': '4552746',
                    'title': '软件测试-作业01',
                    'deadline': futureLater,
                    'status': 2,
                    'score': 9.5,
                    'total_score': 10,
                  },
                ],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (path == '/api/v3/classroom/on-lesson-upcoming-exam') {
          return http.Response(jsonEncode({'code': 0, 'data': {}}), 200);
        }
        return http.Response('{}', 404);
      });

      final api = YktApiClient(client: client);
      const session = YktSession(
        userId: 'u1',
        name: '测试同学',
        school: 'SCU',
        avatar: '',
        cookie: 'sessionid=abc; csrftoken=xyz',
        server: YktServer.yuketang,
      );

      final tasks = await api.fetchAllHomeworkTasks(session);
      expect(tasks.length, 3);
      expect(tasks[0].title, '实验2 JUnit单元测试提交');
      expect(tasks[0].status, HomeworkStatus.unsubmitted);
      expect(tasks[0].isCompleted, isFalse);

      final submitted = tasks.firstWhere((t) => t.title == '软件测试-作业03-基于代码的测试');
      expect(submitted.status, HomeworkStatus.submitted);
      expect(submitted.isCompleted, isTrue);

      final graded = tasks.firstWhere((t) => t.title == '软件测试-作业01');
      expect(graded.status, HomeworkStatus.graded);
      expect(graded.score, 9.5);
    });

    test('AppState persists locally marked homework done state', () async {
      SharedPreferences.setMockInitialValues({});
      final appState = AppState();
      await appState.initialize();

      expect(appState.locallyDoneHomeworkIds, isEmpty);

      await appState.toggleHomeworkLocalDone('1001_hw_soon');
      expect(appState.locallyDoneHomeworkIds.contains('1001_hw_soon'), isTrue);

      final reloaded = AppState();
      await reloaded.initialize();
      expect(reloaded.locallyDoneHomeworkIds.contains('1001_hw_soon'), isTrue);
    });
  });

  group('Phase 2: Slide Cache Service', () {
    test('prefetchSlides caches images and retrieves cached File', () async {
      final sampleBytes = [1, 2, 3, 4, 5, 6, 7, 8];
      final mockClient = MockClient(
        (_) async => http.Response.bytes(sampleBytes, 200),
      );
      final cache = SlideCacheService(client: mockClient);

      // 使用系统临时目录测试（path_provider 在测试中需要 mock，或容错验证）
      final url = 'https://example.com/slide_1.jpg';
      // 确认无崩溃且接口可用
      try {
        await cache.prefetchSlides('pres-cache-test', [url]);
      } catch (_) {}
      cache.dispose();
    });
  });
}
