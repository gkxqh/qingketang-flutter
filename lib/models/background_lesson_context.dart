class BackgroundLessonContext {
  const BackgroundLessonContext({
    required this.lessonId,
    required this.lessonName,
    required this.lessonToken,
    required this.bearerToken,
    required this.serverId,
    required this.userId,
  });

  final String lessonId;
  final String lessonName;
  final String lessonToken;
  final String bearerToken;
  final String serverId;
  final String userId;

  bool get isValid =>
      lessonId.isNotEmpty && lessonToken.isNotEmpty && userId.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'lesson_id': lessonId,
    'lesson_name': lessonName,
    'lesson_token': lessonToken,
    'bearer_token': bearerToken,
    'server_id': serverId,
    'user_id': userId,
  };

  factory BackgroundLessonContext.fromJson(Map<String, dynamic> json) {
    return BackgroundLessonContext(
      lessonId: '${json['lesson_id'] ?? ''}',
      lessonName: '${json['lesson_name'] ?? '雨课堂课堂'}',
      lessonToken: '${json['lesson_token'] ?? ''}',
      bearerToken: '${json['bearer_token'] ?? ''}',
      serverId: '${json['server_id'] ?? 'yuketang'}',
      userId: '${json['user_id'] ?? ''}',
    );
  }
}
