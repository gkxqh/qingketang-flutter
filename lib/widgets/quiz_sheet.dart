import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/answer_draft.dart';
import '../models/problem_view_state.dart';
import '../models/submission_job.dart';
import '../models/ykt_problem.dart';

typedef AnswerUploader = Future<UploadedAnswerImage> Function(XFile file);
typedef AnswerSubmitter = Future<AnswerSubmitResult> Function(
  Object answer,
  bool retry,
);

class QuizSheet extends StatefulWidget {
  const QuizSheet({
    required this.viewListenable,
    required this.allowOvertime,
    required this.uploadImage,
    required this.onSubmit,
    required this.onSavePreselection,
    required this.onClearPreselection,
    this.onCancelAutoSubmit,
    this.autoSubmitEnabled = false,
    this.autoSubmitDelaySeconds = 3,
    super.key,
  });

  final ValueListenable<ProblemViewState> viewListenable;
  final bool allowOvertime;
  final AnswerUploader uploadImage;
  final AnswerSubmitter onSubmit;
  final Future<void> Function(AnswerDraft draft) onSavePreselection;
  final Future<void> Function(String problemId) onClearPreselection;
  final Future<void> Function()? onCancelAutoSubmit;
  final bool autoSubmitEnabled;
  final int autoSubmitDelaySeconds;

  @override
  State<QuizSheet> createState() => _QuizSheetState();
}

class _QuizSheetState extends State<QuizSheet> {
  final Set<String> _selected = {};
  final List<TextEditingController> _fillControllers = [];
  final _subjectiveController = TextEditingController();
  final List<UploadedAnswerImage> _images = [];
  final _picker = ImagePicker();
  Timer? _timer;
  bool _submitting = false;
  bool _uploading = false;
  bool _cancelingAutoSubmit = false;
  bool _dirty = false;
  bool _suppressDirty = false;
  AnswerDraft? _savedDraft;
  SubmissionJob? _job;
  late YktProblem _problem;
  int _remaining = 0;

  YktProblem get problem => _problem;

  bool get _retry => problem.isClosed || problem.isOverdue;
  bool get _blocked => _retry && !widget.allowOvertime;
  bool get _locked => problem.isSubmitted;
  bool get _preselectionSaved => _savedDraft?.hasAnswer == true && !_dirty;
  bool get _hasSavedSnapshot => _savedDraft?.hasAnswer == true;
  bool get _hasCurrentAnswer {
    if (problem.isChoice) return _selected.isNotEmpty;
    if (problem.isFill) {
      return _fillControllers.any((item) => item.text.trim().isNotEmpty);
    }
    return _subjectiveController.text.trim().isNotEmpty || _images.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    final view = widget.viewListenable.value;
    _problem = view.problem;
    _job = view.job;
    _savedDraft = view.draft;
    _hydrateAnswer(view.draft);
    _updateRemaining();
    _syncCountdownTimer();
    _subjectiveController.addListener(_markDirty);
    widget.viewListenable.addListener(_handleViewChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.viewListenable.removeListener(_handleViewChanged);
    for (final controller in _fillControllers) {
      controller.dispose();
    }
    _subjectiveController.dispose();
    super.dispose();
  }

  void _handleViewChanged() {
    if (!mounted) return;
    final view = widget.viewListenable.value;
    if (view.problem.id != problem.id) return;
    setState(() {
      _problem = view.problem;
      _job = view.job;
      _savedDraft = view.draft;
      _updateRemaining();
    });
    _syncCountdownTimer();
  }

  void _updateRemaining() {
    _remaining = problem.remainingSeconds;
  }

  void _syncCountdownTimer() {
    final shouldRun =
        problem.limit > 0 && !problem.isSubmitted && !problem.isClosed;
    if (shouldRun && (_timer == null || !_timer!.isActive)) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(_updateRemaining);
      });
    } else if (!shouldRun) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _hydrateAnswer(AnswerDraft? initialDraft) {
    final answer = !problem.isSubmitted && initialDraft != null
        ? initialDraft.answer
        : problem.userAnswer;
    if (problem.isChoice && answer != null) {
      if (answer is List) {
        _selected.addAll(answer.map((item) => '$item'));
      } else {
        _selected.add('$answer');
      }
    }
    if (problem.isFill) {
      final matches = RegExp(r'[\[【(（]\s*填空\s*\d*\s*[\]】)）]|_{3,}')
          .allMatches(problem.body)
          .length;
      final answers = answer is List
          ? answer.map((item) => '$item').toList()
          : <String>[];
      final count = math.max(matches > 0 ? matches : 1, answers.length);
      for (var index = 0; index < count; index++) {
        final controller = TextEditingController(
          text: index < answers.length ? answers[index] : '',
        )..addListener(_markDirty);
        _fillControllers.add(controller);
      }
    }
    if (problem.isSubjective) {
      if (answer is Map) {
        _subjectiveController.text = '${answer['content'] ?? ''}';
        final pics = answer['pics'];
        if (pics is List) {
          for (final pic in pics.whereType<Map>()) {
            final map = Map<String, dynamic>.from(pic);
            if ('${map['pic'] ?? ''}'.isNotEmpty) {
              _images.add(
                UploadedAnswerImage(
                  pic: '${map['pic']}',
                  thumb: '${map['thumb'] ?? map['pic']}',
                ),
              );
            }
          }
        }
      } else if (answer != null) {
        _subjectiveController.text = '$answer';
      }
    }
  }

  void _markDirty() {
    if (_suppressDirty || !mounted) return;
    if (!_dirty) setState(() => _dirty = true);
  }

  AnswerDraft _currentDraft() {
    return AnswerDraft(
      problemId: problem.id,
      problemType: problem.type,
      selectedOptions: _selected.toList(),
      fillAnswers: _fillControllers.map((item) => item.text).toList(),
      subjectiveContent: _subjectiveController.text,
      images: _images.map((item) => item.toJson()).toList(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _savePreselection() async {
    if (!_hasCurrentAnswer) {
      _show('请先选择或填写答案');
      return;
    }
    final draft = _currentDraft();
    await widget.onSavePreselection(draft);
    if (!mounted) return;
    setState(() {
      _savedDraft = draft;
      _dirty = false;
    });
    _show(
      widget.autoSubmitEnabled ? '预选答案已保存，老师发布后将自动提交' : '预选答案已保存',
      success: true,
    );
  }

  Future<void> _clearPreselection() async {
    _suppressDirty = true;
    setState(() {
      _selected.clear();
      for (final controller in _fillControllers) {
        controller.clear();
      }
      _subjectiveController.clear();
      _images.clear();
      _savedDraft = null;
      _dirty = false;
    });
    _suppressDirty = false;
    await widget.onClearPreselection(problem.id);
    if (!mounted) return;
    _show('已撤销预选');
  }

  Future<void> _cancelAutoSubmit() async {
    final callback = widget.onCancelAutoSubmit;
    if (callback == null || _cancelingAutoSubmit) return;
    setState(() => _cancelingAutoSubmit = true);
    try {
      await callback();
    } finally {
      if (mounted) setState(() => _cancelingAutoSubmit = false);
    }
  }

  Future<void> _pickImages() async {
    if (_uploading || _locked || _images.length >= 9) return;
    try {
      final files = await _picker.pickMultiImage(imageQuality: 82);
      if (files.isEmpty) return;
      setState(() => _uploading = true);
      for (final file in files.take(9 - _images.length)) {
        final uploaded = await widget.uploadImage(file);
        if (!mounted) return;
        setState(() => _images.add(uploaded));
        _markDirty();
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('图片上传失败：$error')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _submit() async {
    if (_locked || _submitting) return;
    if (_blocked) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该题已关闭，当前设置不允许补交')));
      return;
    }
    Object answer;
    if (problem.isChoice) {
      if (_selected.isEmpty) {
        _show('请至少选择一个选项');
        return;
      }
      answer = _selected.toList()..sort();
    } else if (problem.isFill) {
      final values = _fillControllers.map((item) => item.text.trim()).toList();
      if (values.any((item) => item.isEmpty)) {
        _show('请填写全部空格');
        return;
      }
      answer = values;
    } else {
      final content = _subjectiveController.text.trim();
      if (content.isEmpty && _images.isEmpty) {
        _show('请输入答案或上传图片');
        return;
      }
      answer = {
        'content': content,
        'pics': _images.isEmpty
            ? [
                {'pic': '', 'thumb': ''},
              ]
            : _images.map((item) => item.toJson()).toList(),
        'videos': <Object>[],
      };
    }
    setState(() => _submitting = true);
    try {
      final result = await widget.onSubmit(answer, _retry);
      if (!mounted) return;
      if (result.success) {
        problem.markAnswerState(ProblemAnswerState.submittedByMe);
        problem.userAnswer = answer;
        _show(result.message, success: true);
      } else if (result.isAlreadyAnswered) {
        problem.markAnswerState(ProblemAnswerState.answeredElsewhere);
        _show(result.message);
      } else {
        _show(result.message);
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _show(String message, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? const Color(0xFF216B42) : null,
      ),
    );
  }

  Future<void> _previewImage(String url) async {
    if (url.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: const Color(0xFF101512),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Center(
                      child: Text(
                        '题图加载失败',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: IconButton.filledTonal(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        18,
        12,
        18,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF3B4641) : const Color(0xFFD1D5D2),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  problem.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _StatusPill(problem: problem, remaining: _remaining, job: _job),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '第 ${problem.page} 页 · ${problem.isPublished ? '已发布' : '尚未发布'}',
            style: const TextStyle(color: Color(0xFF69716D)),
          ),
          if (problem.coverUrl.isNotEmpty) ...[
            const SizedBox(height: 16),
            GestureDetector(
              onTap: () => _previewImage(problem.coverUrl),
              child: Container(
                constraints: const BoxConstraints(maxHeight: 230),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF171C19),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.network(
                  problem.coverUrl,
                  key: ValueKey('quiz-cover:${problem.coverUrl}'),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 100,
                    child: Center(
                      child: Text(
                        '题图加载失败',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (problem.body.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF222825) : const Color(0xFFF3F5F4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: _ProblemHtml(
                content: problem.body,
                onImageTap: _previewImage,
              ),
            ),
          ],
          const SizedBox(height: 18),
          if (problem.isChoice)
            ...problem.options.map(
              (option) => Padding(
                padding: const EdgeInsets.only(bottom: 9),
                child: _OptionTile(
                  option: option,
                  selected: _selected.contains(option.label),
                  disabled: _locked,
                  onTap: () {
                    if (_locked) return;
                    setState(() {
                      if (problem.isMultiple) {
                        if (!_selected.remove(option.label)) {
                          _selected.add(option.label);
                        }
                      } else {
                        _selected
                          ..clear()
                          ..add(option.label);
                      }
                    });
                    _markDirty();
                  },
                ),
              ),
            )
          else if (problem.isFill)
            ...List.generate(
              _fillControllers.length,
              (index) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: _fillControllers[index],
                  enabled: !_locked,
                  decoration: InputDecoration(
                    labelText: _fillControllers.length == 1
                        ? '填空答案'
                        : '第 ${index + 1} 空',
                  ),
                ),
              ),
            )
          else ...[
            TextField(
              controller: _subjectiveController,
              enabled: !_locked,
              minLines: 4,
              maxLines: 8,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: '简答内容',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '作答配图 ${_images.length}/9',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _locked || _uploading ? null : _pickImages,
                  icon: _uploading
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('添加图片'),
                ),
              ],
            ),
            if (_images.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final image in _images)
                    Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            image.thumb,
                            width: 82,
                            height: 82,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 82,
                              height: 82,
                              color: const Color(0xFFE7E9E7),
                              child: const Icon(Icons.image_not_supported),
                            ),
                          ),
                        ),
                        if (!_locked)
                          Positioned(
                            right: 2,
                            top: 2,
                            child: InkWell(
                              onTap: () {
                                setState(() => _images.remove(image));
                                _markDirty();
                              },
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  size: 13,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ],
          ],
          if (widget.autoSubmitEnabled && !problem.isPublished) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF4F1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '已开启预选自动提交。保存答案后，老师发布题目将等待 '
                '${widget.autoSubmitDelaySeconds} 秒自动提交。',
                style: const TextStyle(color: Color(0xFF176B62), height: 1.5),
              ),
            ),
          ],
          if (_job != null && _job!.state == SubmissionJobState.scheduled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFEAF4F1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      widget.autoSubmitEnabled
                          ? '预选答案已匹配发布题目，等待自动提交。'
                          : '预选答案已匹配发布题目，但自动提交当前已关闭。',
                      style: const TextStyle(
                        color: Color(0xFF176B62),
                        height: 1.5,
                      ),
                    ),
                  ),
                  if (widget.autoSubmitEnabled &&
                      widget.onCancelAutoSubmit != null)
                    TextButton(
                      onPressed: _cancelingAutoSubmit
                          ? null
                          : _cancelAutoSubmit,
                      child: Text(_cancelingAutoSubmit ? '取消中…' : '取消'),
                    ),
                ],
              ),
            ),
          ],
          if (_hasSavedSnapshot && _dirty) ...[
            const SizedBox(height: 12),
            const Text(
              '当前修改尚未保存；自动提交会继续使用上一次已确认的预选答案。',
              style: TextStyle(color: Color(0xFF8A4C18), height: 1.5),
            ),
          ],
          const SizedBox(height: 20),
          if (_retry && !_locked)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _blocked
                    ? const Color(0xFFF7E8E5)
                    : const Color(0xFFFFF5E9),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                _blocked ? '题目已关闭，当前设置不允许补交。' : '已超过原定时限，将尝试调用雨课堂补交通道。',
                style: TextStyle(
                  color: _blocked
                      ? const Color(0xFF9A3F35)
                      : const Color(0xFF8A4C18),
                ),
              ),
            ),
          const SizedBox(height: 12),
          if (!problem.isPublished &&
              !problem.isSubmitted &&
              (_hasCurrentAnswer || _hasSavedSnapshot))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: _clearPreselection,
                icon: Icon(
                  _hasSavedSnapshot
                      ? Icons.undo_rounded
                      : Icons.clear_all_rounded,
                ),
                label: Text(_hasSavedSnapshot ? '撤销预选' : '清除选择'),
              ),
            ),
          FilledButton.icon(
            onPressed: !problem.isPublished
                ? (_hasCurrentAnswer ? _savePreselection : null)
                : _locked || _blocked || _submitting
                ? null
                : _submit,
            icon: !problem.isPublished
                ? Icon(
                    _preselectionSaved
                        ? Icons.check_circle_outline_rounded
                        : Icons.bookmark_add_outlined,
                  )
                : _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(problem.isSubmitted ? Icons.check_rounded : Icons.send),
            label: Text(
              problem.answerState == ProblemAnswerState.answeredElsewhere
                  ? '已在其他客户端作答'
                  : problem.answerState == ProblemAnswerState.submittedByMe
                  ? '已提交'
                  : !problem.isPublished
                  ? !_hasCurrentAnswer
                        ? '请选择或填写答案'
                        : _preselectionSaved
                        ? '预选已保存 · 等待老师发布'
                        : '保存预选答案'
                  : _submitting
                  ? '正在提交…'
                  : _retry
                  ? '提交补交'
                  : '提交作答',
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.option,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  final ProblemOption option;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;

    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: isDark ? 0.22 : 0.09)
              : (isDark ? const Color(0xFF222926) : Colors.white),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? primary
                : (isDark ? const Color(0xFF35413B) : const Color(0xFFDADDD9)),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? primary
                    : (isDark ? const Color(0xFF2E3833) : const Color(0xFFF1F3F2)),
                shape: BoxShape.circle,
              ),
              child: Text(
                option.label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : (isDark ? const Color(0xFFD6DFDC) : const Color(0xFF4D5652)),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _ProblemHtml(
                content: option.text.isEmpty ? option.label : option.text,
                compact: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProblemHtml extends StatelessWidget {
  const _ProblemHtml({
    required this.content,
    this.compact = false,
    this.onImageTap,
  });

  final String content;
  final bool compact;
  final Future<void> Function(String url)? onImageTap;

  static final _imagePattern = RegExp(
    r'''<img[^>]+src\s*=\s*["']([^"']+)["'][^>]*>''',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final images = _imagePattern
        .allMatches(content)
        .map((match) => match.group(1))
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toList();
    final plainText = content
        .replaceAll(_imagePattern, ' ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (images.isEmpty && !content.contains('<')) {
      return Text(
        content,
        style: TextStyle(
          height: compact ? 1.45 : 1.55,
          fontSize: compact ? 14 : 15,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (plainText.isNotEmpty)
          Text(
            plainText,
            style: TextStyle(
              height: compact ? 1.45 : 1.55,
              fontSize: compact ? 14 : 15,
            ),
          ),
        for (final image in images) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onImageTap == null ? null : () => onImageTap!(image),
            child: Container(
              width: double.infinity,
              constraints: BoxConstraints(maxHeight: compact ? 110 : 220),
              decoration: BoxDecoration(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF1B201D)
                    : const Color(0xFFF2F4F3),
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.network(
                image,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    '题干图片加载失败',
                    style: TextStyle(color: Color(0xFF69716D)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.problem, required this.remaining, this.job});

  final YktProblem problem;
  final int remaining;
  final SubmissionJob? job;

  @override
  Widget build(BuildContext context) {
    final text = problem.answerState == ProblemAnswerState.answeredElsewhere
        ? '已在其他端作答'
        : problem.answerState == ProblemAnswerState.submittedByMe
        ? '我已提交'
        : job?.state == SubmissionJobState.submitting
        ? '提交中'
        : job?.state == SubmissionJobState.unknownOutcome
        ? '结果待确认'
        : job?.state == SubmissionJobState.retryRequired
        ? '待补交'
        : job?.state == SubmissionJobState.authBlocked
        ? '登录已失效'
        : problem.isClosed
        ? '已收题'
        : problem.isOverdue
        ? '已超时'
        : problem.limit <= 0
        ? '不限时'
        : '${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}';
    final success =
        problem.answerState == ProblemAnswerState.submittedByMe ||
        job?.state == SubmissionJobState.succeeded;
    final color = success
        ? const Color(0xFF216B42)
        : problem.answerState == ProblemAnswerState.answeredElsewhere ||
              problem.isClosed ||
              (problem.limit > 0 && remaining <= 0)
        ? const Color(0xFFB85C1E)
        : const Color(0xFF176B62);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}
