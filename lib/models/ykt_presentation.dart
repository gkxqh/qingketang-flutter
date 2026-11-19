class PresentationSlide {
  const PresentationSlide({
    required this.id,
    required this.coverUrl,
    required this.index,
    required this.raw,
  });

  final String id;
  final String coverUrl;
  final int index;
  final Map<String, dynamic> raw;

  Map<String, dynamic>? get embeddedProblem {
    final problem = raw['problem'];
    return problem is Map ? Map<String, dynamic>.from(problem) : null;
  }

  factory PresentationSlide.fromJson(Map<String, dynamic> json, int index) {
    final rawCover = '${json['cover'] ?? json['cover_url'] ?? ''}';
    final cover = rawCover.startsWith('http')
        ? rawCover
        : rawCover.isEmpty
        ? ''
        : 'https://qn-scd1.yuketang.cn/$rawCover';
    return PresentationSlide(
      id: '${json['id'] ?? json['slide_id'] ?? json['sid'] ?? index + 1}',
      coverUrl: cover,
      index: index,
      raw: json,
    );
  }
}

class YktPresentation {
  const YktPresentation({
    required this.id,
    required this.title,
    required this.slides,
    this.empty = false,
  });

  final String id;
  final String title;
  final List<PresentationSlide> slides;
  final bool empty;

  factory YktPresentation.fromJson(Map<String, dynamic> json) {
    final slides = (json['slides'] as List? ?? [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList()
        .asMap()
        .entries
        .map((entry) => PresentationSlide.fromJson(entry.value, entry.key))
        .toList();
    return YktPresentation(
      id: '${json['presentation_id'] ?? json['id'] ?? ''}',
      title: '${json['title'] ?? json['Title'] ?? '课堂课件'}',
      slides: slides,
      empty: json['empty'] == true || slides.isEmpty,
    );
  }
}
