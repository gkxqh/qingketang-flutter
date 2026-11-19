import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/models/answer_draft.dart';
import 'package:gongxiaohu_flutter/models/submission_job.dart';
import 'package:gongxiaohu_flutter/models/ykt_problem.dart';
import 'package:gongxiaohu_flutter/models/ykt_session.dart';
import 'package:gongxiaohu_flutter/services/auto_submit_store.dart';
import 'package:gongxiaohu_flutter/services/submission_coordinator.dart';
import 'package:gongxiaohu_flutter/services/ykt_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _session = YktSession(
  userId: 'u1',
  name: '测试用户',
  avatar: '',
  school: '',
  server: YktServer.yuketang,
  cookie: 'sessionid=test',
);

YktProblem _problem({
  bool published = true,
  int dt = 1760000000000,
  int limit = 60,
}) {
  return YktProblem.fromJson({
    'prob': '42',
    'problemType': 1,
    'title': '单选题',
    'body': '请选择',
    'bullets': [
      {'key': 'A', 'value': '选项 A'},
      {'key': 'B', 'value': '选项 B'},
    ],
    'dt': dt,
    'serverNow': dt,
    'limit': limit,
  }, published: published);
}

AnswerDraft _draft(String problemId) {
  return AnswerDraft(
    problemId: problemId,
    problemType: 1,
    selectedOptions: const ['A'],
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

YktApiClient _api(MockClient client) => YktApiClient(client: client);

http.Response _answerResponse(Map<String, dynamic> body, {int status = 200}) {
  return http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

void main() {
  late AutoSubmitStore store;
  late RuntimeLease lease;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = AutoSubmitStore();
    await store.saveEnabled(true);
    await store.saveDelaySeconds(0);
    lease = await store.acquireOwner(
      owner: RuntimeOwner.foreground,
      lessonId: 'lesson-1',
    );
  });

  test(
    'timeline observation never creates an auto-submit job from a draft',
    () async {
      final problem = _problem();
      await store.saveDraft(_draft(problem.id));
      final coordinator = SubmissionCoordinator(
        api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: false,
      );

      final job = await coordinator.observePublish(problem, live: false);

      expect(job, isNull);
      expect(
        await store.latestJobForProblem(
          lessonId: 'lesson-1',
          problemId: problem.id,
        ),
        isNull,
      );
    },
  );

  test(
    'explicit preselection waits for publish and can be promoted from hello',
    () async {
      final unpublished = _problem(published: false);
      final coordinator = SubmissionCoordinator(
        api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: false,
      );

      final waiting = await coordinator.savePreselection(
        unpublished,
        _draft(unpublished.id),
      );
      expect(waiting?.state, SubmissionJobState.waitingPublish);

      final scheduled = await coordinator.observePublish(
        _problem(),
        live: false,
      );
      expect(scheduled?.state, SubmissionJobState.scheduled);
      expect(scheduled?.publishEpoch, 1760000000000);
    },
  );

  test('teacher close cancels a scheduled task before it is claimed', () async {
    final problem = _problem();
    final coordinator = SubmissionCoordinator(
      api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
      store: store,
      session: _session,
      lessonId: 'lesson-1',
      bearerToken: 'bearer',
      allowOvertime: false,
    );

    await coordinator.savePreselection(problem, _draft(problem.id));
    await coordinator.observeClose(problem.id);

    final job = await coordinator.latestJob(problem.id);
    expect(job?.state, SubmissionJobState.canceledByClose);
  });

  test(
    'user can cancel a scheduled task without deleting the saved draft',
    () async {
      final problem = _problem();
      final coordinator = SubmissionCoordinator(
        api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: false,
      );

      await coordinator.savePreselection(problem, _draft(problem.id));
      expect(await coordinator.cancelAutomaticSubmission(problem.id), isTrue);

      final job = await coordinator.latestJob(problem.id);
      expect(job?.state, SubmissionJobState.canceledByManual);
      expect(await store.readDraft(problem.id), isNotNull);
    },
  );

  test(
    'manual success uses the shared job lock and clears the draft',
    () async {
      final problem = _problem();
      await store.saveDraft(_draft(problem.id));
      final coordinator = SubmissionCoordinator(
        api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: false,
      );

      final result = await coordinator.submitManual(
        problem: problem,
        answer: const ['A'],
        retry: false,
        lease: lease,
      );
      final job = await coordinator.latestJob(problem.id);

      expect(result.success, isTrue);
      expect(job?.state, SubmissionJobState.succeeded);
      expect(await store.readDraft(problem.id), isNull);
    },
  );

  test('50028 records answered elsewhere instead of submitted by me', () async {
    final problem = _problem();
    await store.saveDraft(_draft(problem.id));
    final coordinator = SubmissionCoordinator(
      api: _api(
        MockClient(
          (_) async =>
              _answerResponse({'code': 50028, 'msg': '该题目已在其他客户端完成作答'}),
        ),
      ),
      store: store,
      session: _session,
      lessonId: 'lesson-1',
      bearerToken: 'bearer',
      allowOvertime: true,
    );

    final result = await coordinator.submitManual(
      problem: problem,
      answer: const ['A'],
      retry: false,
      lease: lease,
    );
    final job = await coordinator.latestJob(problem.id);

    expect(result.success, isFalse);
    expect(result.code, 50028);
    expect(job?.state, SubmissionJobState.alreadyAnswered);
    expect(await store.readDraft(problem.id), isNull);
  });

  test(
    'closed answer channel retries only when overtime policy is enabled',
    () async {
      final problem = _problem();
      var requests = 0;
      final coordinator = SubmissionCoordinator(
        api: _api(
          MockClient((request) async {
            requests++;
            if (request.url.path.endsWith('/problem/answer')) {
              return _answerResponse({
                'code': 50026,
                'msg': 'LESSON_PROBLEM_CLOSED',
              });
            }
            return _answerResponse({'code': 0});
          }),
        ),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: true,
      );

      final result = await coordinator.submitManual(
        problem: problem,
        answer: const ['A'],
        retry: false,
        lease: lease,
      );

      expect(result.success, isTrue);
      expect(requests, 2);
    },
  );

  test(
    'safely marks job as terminalFailed when draft answer is null instead of crashing',
    () async {
      await store.saveEnabled(true);
      await store.saveDelaySeconds(0);
      final coordinator = SubmissionCoordinator(
        api: _api(MockClient((_) async => _answerResponse({'code': 0}))),
        store: store,
        session: _session,
        lessonId: 'lesson-1',
        bearerToken: 'bearer',
        allowOvertime: true,
      );

      final emptyDraft = AnswerDraft(
        problemId: 'prob-invalid',
        problemType: 999, // unknown type returns answer == null
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      final job = SubmissionJob(
        lessonId: 'lesson-1',
        problemId: 'prob-invalid',
        problemType: 999,
        problemDt: 1000,
        title: '未知题型',
        draft: emptyDraft,
        state: SubmissionJobState.scheduled,
        trigger: SubmissionTrigger.automatic,
        createdAt: now,
        updatedAt: now,
        scheduledAt: now - 10,
      );
      await store.saveJob(job);

      final changed = await coordinator.runDueJobs(lease: lease);
      expect(changed, isNotEmpty);
      expect(changed.first.state, SubmissionJobState.terminalFailed);
      expect(changed.first.lastMessage, contains('作答内容为空'));
    },
  );
}
