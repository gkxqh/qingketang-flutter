import 'package:flutter_test/flutter_test.dart';
import 'package:gongxiaohu_flutter/core/lesson_qr.dart';
import 'package:gongxiaohu_flutter/models/ykt_lesson.dart';
import 'package:gongxiaohu_flutter/models/ykt_session.dart';
import 'package:gongxiaohu_flutter/services/app_state.dart';
import 'package:gongxiaohu_flutter/services/ykt_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('parses lesson ids from common classroom QR formats', () {
    const id = '1817290075055332992';
    expect(
      parseLessonIdFromQr(
        'https://www.yuketang.cn/lesson/fullscreen/v3?lessonId=$id',
      ),
      id,
    );
    expect(parseLessonIdFromQr('yuketang://join?classroom_id=$id'), id);
    expect(parseLessonIdFromQr('https://ykt.io/lesson/$id'), id);
    expect(parseLessonIdFromQr(id), id);
    expect(parseLessonIdFromQr('https://example.com/not-a-class'), isNull);
  });

  test('keeps checked-in status and fresh lesson tokens after refresh', () {
    const lessonId = '1817290075055332992';
    final fetched = [
      const YktLesson(
        id: lessonId,
        name: '测试课堂',
        teacher: '',
        classroom: '',
        startTime: 0,
        raw: {},
      ),
    ];
    final previous = [fetched.first.copyWith(isCheckedIn: true)];
    final tokens = {
      lessonId: YktLessonToken(
        lessonId: lessonId,
        lessonToken: 'lesson-token',
        bearerToken: 'bearer',
        activePresentationId: '',
        presentationList: const [],
        savedAt: DateTime.now(),
      ),
    };

    final merged = mergeLessonCheckinStatus(
      fetched,
      previous: previous,
      tokens: tokens,
    );

    expect(merged.single.isCheckedIn, isTrue);
  });

  test('local home profile preferences are persisted independently', () async {
    SharedPreferences.setMockInitialValues({});
    final store = YktSessionStore();

    await store.saveHideHomeProfile(true);
    await store.saveHomeNickname('本地昵称');
    await store.saveHomeAvatarPath('/tmp/avatar.jpg');
    await store.saveHomeNoticeEnabled(false);

    expect(await store.readHideHomeProfile(), isTrue);
    expect(await store.readHomeNickname(), '本地昵称');
    expect(await store.readHomeAvatarPath(), '/tmp/avatar.jpg');
    expect(await store.readHomeNoticeEnabled(), isFalse);
  });
}
