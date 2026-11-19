class AnswerDraft {
  const AnswerDraft({
    required this.problemId,
    required this.problemType,
    this.selectedOptions = const [],
    this.fillAnswers = const [],
    this.subjectiveContent = '',
    this.images = const [],
    this.updatedAt = 0,
  });

  final String problemId;
  final int problemType;
  final List<String> selectedOptions;
  final List<String> fillAnswers;
  final String subjectiveContent;
  final List<Map<String, dynamic>> images;
  final int updatedAt;

  bool get hasAnswer => switch (problemType) {
    1 || 2 || 3 => selectedOptions.isNotEmpty,
    4 => fillAnswers.any((answer) => answer.trim().isNotEmpty),
    5 =>
      subjectiveContent.trim().isNotEmpty ||
          images.any((image) => '${image['pic'] ?? ''}'.isNotEmpty),
    _ => false,
  };

  Object? get answer => switch (problemType) {
    1 || 2 || 3 => [...selectedOptions]..sort(),
    4 => fillAnswers.map((answer) => answer.trim()).toList(),
    5 => {
      'content': subjectiveContent.trim(),
      'pics': images.isEmpty
          ? [
              {'pic': '', 'thumb': ''},
            ]
          : images,
      'videos': <Object>[],
    },
    _ => null,
  };

  Map<String, dynamic> toJson() => {
    'problem_id': problemId,
    'problem_type': problemType,
    'selected_options': selectedOptions,
    'fill_answers': fillAnswers,
    'subjective_content': subjectiveContent,
    'images': images,
    'updated_at': updatedAt,
  };

  factory AnswerDraft.fromJson(Map<String, dynamic> json) {
    return AnswerDraft(
      problemId: '${json['problem_id'] ?? ''}',
      problemType: int.tryParse('${json['problem_type'] ?? 1}') ?? 1,
      selectedOptions: (json['selected_options'] as List? ?? [])
          .map((item) => '$item')
          .toList(),
      fillAnswers: (json['fill_answers'] as List? ?? [])
          .map((item) => '$item')
          .toList(),
      subjectiveContent: '${json['subjective_content'] ?? ''}',
      images: (json['images'] as List? ?? [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(),
      updatedAt: int.tryParse('${json['updated_at'] ?? 0}') ?? 0,
    );
  }
}
