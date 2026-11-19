import 'answer_draft.dart';
import 'submission_job.dart';
import 'ykt_problem.dart';

class ProblemViewState {
  const ProblemViewState({required this.problem, this.draft, this.job});

  final YktProblem problem;
  final AnswerDraft? draft;
  final SubmissionJob? job;
}
