enum YktServer {
  yuketang(
    id: 'yuketang',
    label: '通用雨课堂',
    domain: 'https://www.yuketang.cn',
    socketUrl: 'wss://www.yuketang.cn/wsapp/',
  ),
  changjiang(
    id: 'changjiang',
    label: '长江雨课堂',
    domain: 'https://changjiang.yuketang.cn',
    socketUrl: 'wss://changjiang.yuketang.cn/wsapp/',
  ),
  pro(
    id: 'pro',
    label: '荷塘雨课堂 Pro',
    domain: 'https://pro.yuketang.cn',
    socketUrl: 'wss://pro.yuketang.cn/wsapp/',
  ),
  huanghe(
    id: 'huanghe',
    label: '黄河雨课堂',
    domain: 'https://huanghe.yuketang.cn',
    socketUrl: 'wss://huanghe.yuketang.cn/wsapp/',
  );

  const YktServer({
    required this.id,
    required this.label,
    required this.domain,
    required this.socketUrl,
  });

  final String id;
  final String label;
  final String domain;
  final String socketUrl;

  static YktServer fromId(String? id) {
    return YktServer.values.firstWhere(
      (server) => server.id == id,
      orElse: () => YktServer.yuketang,
    );
  }
}

class YktSession {
  const YktSession({
    required this.userId,
    required this.name,
    required this.avatar,
    required this.school,
    required this.server,
    required this.cookie,
    this.phoneNumber = '',
  });

  final String userId;
  final String name;
  final String avatar;
  final String school;
  final YktServer server;
  final String cookie;
  final String phoneNumber;

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'name': name,
    'avatar': avatar,
    'school': school,
    'server': server.id,
    'cookie': cookie,
    'phone_number': phoneNumber,
  };

  factory YktSession.fromJson(Map<String, dynamic> json) {
    return YktSession(
      userId: '${json['user_id'] ?? json['userId'] ?? ''}',
      name: '${json['name'] ?? '雨课堂学员'}',
      avatar: '${json['avatar'] ?? ''}',
      school: '${json['school'] ?? ''}',
      server: YktServer.fromId(json['server'] as String?),
      cookie: '${json['cookie'] ?? ''}',
      phoneNumber: '${json['phone_number'] ?? ''}',
    );
  }

  YktSession copyWith({
    String? userId,
    String? name,
    String? avatar,
    String? school,
    YktServer? server,
    String? cookie,
    String? phoneNumber,
  }) {
    return YktSession(
      userId: userId ?? this.userId,
      name: name ?? this.name,
      avatar: avatar ?? this.avatar,
      school: school ?? this.school,
      server: server ?? this.server,
      cookie: cookie ?? this.cookie,
      phoneNumber: phoneNumber ?? this.phoneNumber,
    );
  }
}

class YktLessonToken {
  const YktLessonToken({
    required this.lessonId,
    required this.lessonToken,
    required this.bearerToken,
    required this.activePresentationId,
    required this.presentationList,
    required this.savedAt,
  });

  final String lessonId;
  final String lessonToken;
  final String bearerToken;
  final String activePresentationId;
  final List<String> presentationList;
  final DateTime savedAt;

  bool get isFresh =>
      DateTime.now().difference(savedAt) < const Duration(hours: 4);

  Map<String, dynamic> toJson() => {
    'lesson_id': lessonId,
    'lesson_token': lessonToken,
    'bearer_token': bearerToken,
    'active_presentation_id': activePresentationId,
    'presentation_list': presentationList,
    'saved_at': savedAt.toIso8601String(),
  };

  factory YktLessonToken.fromJson(Map<String, dynamic> json) {
    return YktLessonToken(
      lessonId: '${json['lesson_id'] ?? ''}',
      lessonToken: '${json['lesson_token'] ?? ''}',
      bearerToken: '${json['bearer_token'] ?? ''}',
      activePresentationId: '${json['active_presentation_id'] ?? ''}',
      presentationList: (json['presentation_list'] as List? ?? [])
          .map((e) => '$e')
          .toList(),
      savedAt: DateTime.tryParse('${json['saved_at'] ?? ''}') ?? DateTime.now(),
    );
  }
}
