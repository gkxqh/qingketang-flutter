import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/models/ykt_session.dart';
import 'package:gongxiaohu_flutter/core/cookie_utils.dart';
import 'package:gongxiaohu_flutter/models/answer_draft.dart';
import 'package:gongxiaohu_flutter/models/classroom_event.dart';
import 'package:gongxiaohu_flutter/models/ykt_lesson.dart';
import 'package:gongxiaohu_flutter/models/ykt_problem.dart';
import 'package:gongxiaohu_flutter/services/auto_submit_store.dart';
import 'package:gongxiaohu_flutter/services/ykt_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('maps Rain Classroom servers by id', () {
    expect(YktServer.fromId('changjiang'), YktServer.changjiang);
    expect(YktServer.fromId('unknown'), YktServer.yuketang);
  });

  test('parses cookie headers without attribute values', () {
    final cookies = parseResponseCookies({
      'set-cookie':
          'sessionid=abc; Path=/; HttpOnly, csrftoken=xyz; Path=/; Secure',
    });
    expect(cookies['sessionid'], 'abc');
    expect(cookies['csrftoken'], 'xyz');
    expect(cookies.containsKey('Path'), isFalse);
    expect(joinCookies(cookies), 'sessionid=abc; csrftoken=xyz');
  });

  test('parses multiple choice problem and submitted answer', () {
    final problem = YktProblem.fromJson({
      'id': 'prob-42',
      'problemType': 2,
      'body': '选择正确项',
      'bullets': [
        {'key': 'A', 'value': '选项 A'},
        {'key': 'B', 'value': '选项 B'},
      ],
      'limit': 30,
      'dt': 1760000000,
      'result': ['A', 'B'],
    });
    expect(problem.id, '42');
    expect(problem.type, 2);
    expect(problem.isMultiple, isTrue);
    expect(problem.isSubmitted, isTrue);
    expect(problem.options.map((item) => item.label), ['A', 'B']);
  });

  test('recognizes subjective problem from title keyword', () {
    final problem = YktProblem.fromJson({
      'prob': '99',
      'title': '主观简答题',
      'body': '请说明你的思路',
    });
    expect(problem.type, 5);
    expect(problem.isSubjective, isTrue);
  });

  test(
    'countdown follows the server clock and extension reopens the problem',
    () {
      final now = DateTime.now().millisecondsSinceEpoch;
      final problem = YktProblem.fromJson({
        'prob': 'clock-1',
        'problemType': 1,
        'dt': now - 20000,
        'serverNow': now - 10000,
        'limit': 60,
      });

      expect(problem.remainingSeconds, inInclusiveRange(49, 50));
      problem
        ..markClosed()
        ..extendBy(30);

      expect(problem.isClosed, isFalse);
      expect(problem.limit, 90);
      expect(problem.extend, 30);
    },
  );

  test('absolute extension restores a positive countdown after timeout', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final problem = YktProblem.fromJson({
      'prob': 'clock-2',
      'problemType': 1,
      'dt': now - 70000,
      'serverNow': now,
      'limit': 60,
    });
    expect(problem.isOverdue, isTrue);

    final extension = problem.extendBy(0, absoluteLimit: 90);

    expect(extension, 30);
    expect(problem.limit, 90);
    expect(problem.isOverdue, isFalse);
    expect(problem.remainingSeconds, greaterThan(0));
  });

  test('does not treat snowflake lesson ids as timestamps', () {
    final lesson = YktLesson.fromJson({
      'lessonId': '1817182935602802560',
      'name': '测试课堂',
    });
    expect(lesson.id, '1817182935602802560');
    expect(lesson.startTime, 0);
  });

  test('on-lesson code 50000 is treated as an expired session', () async {
    final api = YktApiClient(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({'code': 50000, 'message': '登录状态已过期'}),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    const session = YktSession(
      userId: 'u1',
      name: '测试用户',
      avatar: '',
      school: '',
      server: YktServer.yuketang,
      cookie: 'sessionid=expired',
    );
    await expectLater(
      api.fetchOnLesson(session),
      throwsA(
        isA<YktApiException>()
            .having((error) => error.code, 'code', 50000)
            .having((error) => error.message, 'message', '登录状态已过期'),
      ),
    );
  });

  test('HTML user-info response is not treated as a valid session', () async {
    final api = YktApiClient(
      client: MockClient((_) async => http.Response('<html>login</html>', 200)),
    );
    const session = YktSession(
      userId: 'u1',
      name: '测试用户',
      avatar: '',
      school: '',
      server: YktServer.yuketang,
      cookie: 'sessionid=expired',
    );
    expect(await api.validateSession(session), SessionValidation.unknown);
  });

  test(
    'forced presentation refresh bypasses server and client caches',
    () async {
      late http.Request captured;
      final api = YktApiClient(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'code': 0,
              'data': {
                'presentation_id': 'pres-1',
                'slides': [
                  {'id': 'slide-1', 'cover': 'cover.jpg'},
                ],
              },
            }),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      const session = YktSession(
        userId: 'u1',
        name: '测试用户',
        avatar: '',
        school: '',
        server: YktServer.yuketang,
        cookie: 'sessionid=valid',
      );

      final presentation = await api.fetchPresentation(
        session: session,
        lessonId: 'lesson-1',
        presentationId: 'pres-1',
        bearerToken: 'bearer',
        forceRefresh: true,
      );

      expect(presentation.slides, hasLength(1));
      expect(captured.url.queryParameters['_'], isNotEmpty);
      expect(captured.headers['Cache-Control'], 'no-cache');
      expect(captured.headers['Pragma'], 'no-cache');
    },
  );

  test('parses nested slide navigation payload', () {
    final event = ClassroomEvent(
      op: 'slidenav',
      payload: {
        'op': 'slidenav',
        'slide': {'pres': 'presentation-123', 'si': 10, 'sid': 'slide-11'},
      },
      receivedAt: DateTime.now(),
    );
    expect(event.presentationId, 'presentation-123');
    expect(event.slideIndex, 9);
  });

  test('serializes a preselected choice answer draft', () {
    const draft = AnswerDraft(
      problemId: '42',
      problemType: 2,
      selectedOptions: ['C', 'A'],
      updatedAt: 1,
    );
    final restored = AnswerDraft.fromJson(draft.toJson());
    expect(restored.hasAnswer, isTrue);
    expect(restored.answer, ['A', 'C']);
  });

  test('clearing a preselection removes the stored draft', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AutoSubmitStore();
    await store.saveDraft(
      const AnswerDraft(
        problemId: '42',
        problemType: 1,
        selectedOptions: ['B'],
        updatedAt: 1,
      ),
    );
    expect(await store.readDraft('42'), isNotNull);
    await store.saveDraft(
      const AnswerDraft(problemId: '42', problemType: 1, updatedAt: 2),
    );
    expect(await store.readDraft('42'), isNull);
  });
}
