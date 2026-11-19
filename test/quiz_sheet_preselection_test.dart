import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/models/answer_draft.dart';
import 'package:gongxiaohu_flutter/models/problem_view_state.dart';
import 'package:gongxiaohu_flutter/models/submission_job.dart';
import 'package:gongxiaohu_flutter/models/ykt_problem.dart';
import 'package:gongxiaohu_flutter/widgets/quiz_sheet.dart';

void main() {
  testWidgets(
    'typing or selecting alone does not claim the preselection is saved',
    (tester) async {
      final problem = YktProblem.fromJson({
        'prob': '42',
        'problemType': 1,
        'title': '单选题',
        'body': '请选择',
        'bullets': [
          {'key': 'A', 'value': '选项 A'},
          {'key': 'B', 'value': '选项 B'},
        ],
      }, published: false);
      final view = ValueNotifier(ProblemViewState(problem: problem));
      AnswerDraft? savedDraft;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuizSheet(
              viewListenable: view,
              allowOvertime: true,
              autoSubmitEnabled: true,
              autoSubmitDelaySeconds: 3,
              uploadImage: (_) => throw UnimplementedError(),
              onSavePreselection: (draft) async {
                savedDraft = draft;
              },
              onClearPreselection: (_) async {},
              onSubmit: (_, _) async =>
                  const AnswerSubmitResult(success: false, message: 'unused'),
            ),
          ),
        ),
      );

      expect(find.text('请选择或填写答案'), findsOneWidget);
      expect(find.text('预选已保存 · 等待老师发布'), findsNothing);

      await tester.tap(find.text('选项 A'));
      await tester.pump();
      expect(find.text('保存预选答案'), findsOneWidget);
      expect(find.text('预选已保存 · 等待老师发布'), findsNothing);

      final saveButton = find.text('保存预选答案');
      await tester.ensureVisible(saveButton);
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(savedDraft?.selectedOptions, ['A']);
      expect(find.text('预选已保存 · 等待老师发布'), findsOneWidget);
    },
  );

  testWidgets('scheduled auto-submit banner exposes a cancel action', (
    tester,
  ) async {
    final problem = YktProblem.fromJson({
      'prob': 'scheduled-42',
      'problemType': 1,
      'title': '单选题',
      'body': '请选择',
      'bullets': [
        {'key': 'A', 'value': '选项 A'},
      ],
    });
    final now = DateTime.now().millisecondsSinceEpoch;
    final draft = AnswerDraft(
      problemId: problem.id,
      problemType: 1,
      selectedOptions: const ['A'],
      updatedAt: now,
    );
    final job = SubmissionJob(
      lessonId: 'lesson-1',
      problemId: problem.id,
      problemType: 1,
      problemDt: problem.dt,
      title: problem.title,
      draft: draft,
      state: SubmissionJobState.scheduled,
      trigger: SubmissionTrigger.automatic,
      createdAt: now,
      updatedAt: now,
      scheduledAt: now + 3000,
      publishEpoch: problem.dt,
    );
    final view = ValueNotifier(
      ProblemViewState(problem: problem, draft: draft, job: job),
    );
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuizSheet(
            viewListenable: view,
            allowOvertime: true,
            autoSubmitEnabled: true,
            uploadImage: (_) => throw UnimplementedError(),
            onSavePreselection: (_) async {},
            onClearPreselection: (_) async {},
            onCancelAutoSubmit: () async {
              cancelled = true;
            },
            onSubmit: (_, _) async =>
                const AnswerSubmitResult(success: false, message: 'unused'),
          ),
        ),
      ),
    );

    final cancelButton = find.text('取消');
    await tester.ensureVisible(cancelButton);
    await tester.tap(cancelButton);
    await tester.pumpAndSettle();

    expect(cancelled, isTrue);
  });

  testWidgets(
    'retry warning disappears after a successful overtime submission',
    (tester) async {
      final problem = YktProblem.fromJson({
        'prob': 'closed-42',
        'problemType': 1,
        'title': '单选题',
        'body': '请选择',
        'isClosed': true,
        'bullets': [
          {'key': 'A', 'value': '选项 A'},
          {'key': 'B', 'value': '选项 B'},
        ],
      });
      final view = ValueNotifier(ProblemViewState(problem: problem));

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuizSheet(
              viewListenable: view,
              allowOvertime: true,
              uploadImage: (_) => throw UnimplementedError(),
              onSavePreselection: (_) async {},
              onClearPreselection: (_) async {},
              onSubmit: (_, retry) async {
                expect(retry, isTrue);
                return const AnswerSubmitResult(success: true, message: '补交成功');
              },
            ),
          ),
        ),
      );

      expect(find.text('已超过原定时限，将尝试调用雨课堂补交通道。'), findsOneWidget);
      await tester.tap(find.text('选项 A'));
      await tester.pump();
      final submitButton = find.text('提交补交');
      await tester.ensureVisible(submitButton);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      expect(find.text('已超过原定时限，将尝试调用雨课堂补交通道。'), findsNothing);
      expect(find.text('已提交'), findsOneWidget);
    },
  );

  testWidgets('teacher extension restarts the countdown in an open sheet', (
    tester,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final problem = YktProblem.fromJson({
      'prob': 'extended-42',
      'problemType': 1,
      'title': '单选题',
      'body': '请选择',
      'isClosed': true,
      'dt': now - 50000,
      'serverNow': now,
      'limit': 30,
      'bullets': [
        {'key': 'A', 'value': '选项 A'},
      ],
    });
    final view = ValueNotifier(ProblemViewState(problem: problem));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QuizSheet(
            viewListenable: view,
            allowOvertime: false,
            uploadImage: (_) => throw UnimplementedError(),
            onSavePreselection: (_) async {},
            onClearPreselection: (_) async {},
            onSubmit: (_, _) async =>
                const AnswerSubmitResult(success: false, message: 'unused'),
          ),
        ),
      ),
    );
    expect(find.text('题目已关闭，当前设置不允许补交。'), findsOneWidget);

    problem.extendBy(30);
    view.value = ProblemViewState(problem: problem);
    await tester.pump();

    expect(find.text('题目已关闭，当前设置不允许补交。'), findsNothing);
    final countdown = find.byWidgetPredicate(
      (widget) =>
          widget is Text && RegExp(r'^\d+:\d{2}$').hasMatch(widget.data ?? ''),
    );
    expect(countdown, findsOneWidget);
  });

  testWidgets(
    'restores all fill answers from draft even without fill tags in body',
    (tester) async {
      final problem = YktProblem.fromJson({
        'prob': 'fill-100',
        'problemType': 4,
        'title': '填空题',
        'body': '这是一道图片题，题干没有填空标记',
      }, published: true);
      final draft = AnswerDraft(
        problemId: 'fill-100',
        problemType: 4,
        fillAnswers: ['答案一', '答案二', '答案三'],
      );
      final view = ValueNotifier(
        ProblemViewState(problem: problem, draft: draft),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QuizSheet(
              viewListenable: view,
              allowOvertime: true,
              uploadImage: (_) => throw UnimplementedError(),
              onSavePreselection: (_) async {},
              onClearPreselection: (_) async {},
              onSubmit: (_, _) async =>
                  const AnswerSubmitResult(success: false, message: 'unused'),
            ),
          ),
        ),
      );

      expect(find.byType(TextField), findsNWidgets(3));
      expect(find.text('答案一'), findsOneWidget);
      expect(find.text('答案二'), findsOneWidget);
      expect(find.text('答案三'), findsOneWidget);
    },
  );
}
