import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';

import '../core/cookie_utils.dart';
import '../models/ykt_homework.dart';
import '../models/ykt_lesson.dart';
import '../models/ykt_presentation.dart';
import '../models/ykt_problem.dart';
import '../models/ykt_session.dart';

class YktApiException implements Exception {
  const YktApiException(this.message, {this.code = -1});

  final String message;
  final int code;

  @override
  String toString() => message;
}

class YktApiClient {
  YktApiClient({http.Client? client}) : _client = client ?? http.Client();

  static const gatewayBase = 'https://hnit.jiclub.site';
  static const qiniuBucket = 'cms-attachment';
  static const qiniuTokenPath = '/pc/generate_qiniu_token';

  final http.Client _client;
  String _tempCookie = '';
  String? _deviceId;

  void clearTempCookie() {
    _tempCookie = '';
  }

  void _debugLog(String message) {
    if (kDebugMode) debugPrint('[YktApi] $message');
  }

  Uri _uri(YktServer server, String path, [Map<String, String>? query]) {
    return Uri.parse('${server.domain}$path').replace(queryParameters: query);
  }

  Uri _gateway(String path, [Map<String, String>? query]) {
    return Uri.parse('$gatewayBase$path').replace(queryParameters: query);
  }

  Map<String, String> _mobileHeaders(
    YktServer server, {
    String? cookie,
    String? userId,
  }) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'Referer': '${server.domain}/',
      'user-agent': 'Android',
      'brand': 'google Pixel 9 Pro',
      'uuid': '',
      'buildnumber': '1610',
      'xtua': 'client=app&tag=1.3.3&platform=Android',
      'systemversion': '16',
      'incremental': '14624737',
      'isphysicaldevice': 'true',
      'xtbz': 'ykt',
      'x-client': 'app',
    };
    final effectiveCookie = cookie ?? _tempCookie;
    if (effectiveCookie.isNotEmpty) headers['Cookie'] = effectiveCookie;
    if (userId != null && userId.isNotEmpty) headers['x-uid'] = userId;
    return headers;
  }

  Future<dynamic> _decodeResponse(http.Response response) async {
    if (response.body.isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(response.body);
    } catch (_) {
      return response.body;
    }
  }

  Future<http.Response> _send(
    Future<http.Response> request, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await request.timeout(timeout);
    } on Exception catch (error) {
      throw YktApiException('网络连接失败：$error');
    }
  }

  Future<QrLoginInfo> createQrLogin(YktServer server) async {
    try {
      final response = await _send(
        _client.get(
          _uri(server, '/api/v3/user/login/pre-info'),
          headers: {
            'Accept': 'application/json',
            'Referer': '${server.domain}/',
          },
        ),
        timeout: const Duration(seconds: 8),
      );
      final data = await _decodeResponse(response);
      if (response.statusCode == 200 &&
          data is Map &&
          data['code'] == 0 &&
          data['data'] is Map) {
        final payload = Map<String, dynamic>.from(data['data'] as Map);
        return QrLoginInfo(
          token: '${payload['token'] ?? ''}',
          qrContent: '${payload['qrContent'] ?? payload['qr_content'] ?? ''}',
          qrImage: '${payload['qrImage'] ?? payload['qr_image'] ?? ''}',
        );
      }
    } catch (_) {
      // The gateway is the documented fallback in the APK.
    }

    final response = await _send(
      _client.get(
        _gateway('/api/ykt/auth/qrcode', {'server': server.id}),
        headers: const {'Accept': 'application/json'},
      ),
      timeout: const Duration(seconds: 12),
    );
    final data = await _decodeResponse(response);
    if (response.statusCode == 200 &&
        data is Map &&
        data['code'] == 0 &&
        data['data'] is Map) {
      final payload = Map<String, dynamic>.from(data['data'] as Map);
      return QrLoginInfo(
        token: '${payload['token'] ?? ''}',
        qrContent: '${payload['qrContent'] ?? payload['qr_url'] ?? ''}',
        qrImage: '${payload['qrImage'] ?? payload['qr_image'] ?? ''}',
      );
    }
    throw YktApiException('生成登录二维码失败');
  }

  Future<QrPollResult> pollQrLogin(String token, YktServer server) async {
    final response = await _send(
      _client.post(
        _uri(server, '/api/v3/user/login'),
        headers: _mobileHeaders(server),
        body: jsonEncode({'token': token}),
      ),
      timeout: const Duration(seconds: 40),
    );
    final data = await _decodeResponse(response);
    if (response.statusCode != 200 || data is! Map) {
      return const QrPollResult(state: QrPollState.waiting);
    }
    final code = int.tryParse('${data['code']}') ?? -1;
    if (code == 50400) {
      return const QrPollResult(state: QrPollState.expired);
    }
    if (code != 0) {
      return const QrPollResult(state: QrPollState.waiting);
    }

    final cookie = joinCookies(parseResponseCookies(response.headers));
    final session = await _sessionFromResponse(
      responseData: Map<String, dynamic>.from(data),
      responseHeaders: response.headers,
      server: server,
      cookie: cookie,
    );
    return QrPollResult(state: QrPollState.success, session: session);
  }

  Future<void> sendSmsCode({
    required String phone,
    required YktServer server,
    String ticket = '',
    String rand = '',
  }) async {
    clearTempCookie();
    final response = await _send(
      _client.post(
        _uri(server, '/api/v3/user/code/send'),
        headers: _mobileHeaders(server),
        body: jsonEncode({
          'phoneNumber': phone,
          'email': '',
          'ticket': ticket,
          'rand': rand,
        }),
      ),
    );
    _rememberResponseCookie(response);
    final data = await _decodeResponse(response);
    if (response.statusCode == 200 &&
        data is Map &&
        (data['code'] == 0 || data['success'] == true)) {
      return;
    }

    final pcResponse = await _send(
      _client.post(
        _uri(server, '/pc/login/send_sms_login_code/'),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Referer': '${server.domain}/web',
        },
        body: jsonEncode({
          'mobile': phone,
          'login': true,
          'hcaptcha_token': '',
          'randstr': rand,
          'ticket': ticket,
        }),
      ),
    );
    _rememberResponseCookie(pcResponse);
    final pcData = await _decodeResponse(pcResponse);
    if (pcResponse.statusCode == 200 &&
        pcData is Map &&
        (pcData['code'] == 0 || pcData['success'] == true)) {
      return;
    }
    throw YktApiException(_messageFrom(pcData, '发送验证码失败'));
  }

  Future<YktSession> loginWithSms({
    required String phone,
    required String code,
    required YktServer server,
    String ticket = '',
    String rand = '',
  }) async {
    final verifyResponse = await _send(
      _client.post(
        _uri(server, '/api/v3/user/code/verify'),
        headers: _mobileHeaders(server),
        body: jsonEncode({'phoneNumber': phone, 'email': '', 'code': code}),
      ),
    );
    _rememberResponseCookie(verifyResponse);
    final verifyData = await _decodeResponse(verifyResponse);
    if (verifyResponse.statusCode == 200 &&
        verifyData is Map &&
        verifyData['code'] != null &&
        verifyData['code'] != 0) {
      throw YktApiException(_messageFrom(verifyData, '验证码错误'));
    }

    final response = await _send(
      _client.post(
        _uri(server, '/api/v3/user/login/app'),
        headers: _mobileHeaders(server),
        body: jsonEncode({
          'type': 3,
          'phoneNumber': phone,
          'password': '',
          'email': '',
          'code': code,
          'pushDeviceId': _getDeviceId(),
          'ticket': ticket,
          'rand': rand,
        }),
      ),
    );
    return _loginSessionFromResponse(response, server, phone);
  }

  Future<YktSession> loginWithPassword({
    required String phone,
    required String password,
    required YktServer server,
    String ticket = '',
    String rand = '',
  }) async {
    clearTempCookie();
    final response = await _send(
      _client.post(
        _uri(server, '/api/v3/user/login/app'),
        headers: _mobileHeaders(server),
        body: jsonEncode({
          'type': 1,
          'phoneNumber': phone,
          'password': password,
          'email': '',
          'code': '',
          'pushDeviceId': _getDeviceId(),
          'ticket': ticket,
          'rand': rand,
        }),
      ),
    );
    return _loginSessionFromResponse(response, server, phone);
  }

  Future<YktSession> _loginSessionFromResponse(
    http.Response response,
    YktServer server,
    String phone,
  ) async {
    _rememberResponseCookie(response);
    final data = await _decodeResponse(response);
    if (response.statusCode != 200 ||
        data is! Map ||
        int.tryParse('${data['code']}') != 0) {
      throw YktApiException(_messageFrom(data, '登录失败，请检查账号信息'));
    }
    return _sessionFromResponse(
      responseData: Map<String, dynamic>.from(data),
      responseHeaders: response.headers,
      server: server,
      cookie: _tempCookie,
      phone: phone,
    );
  }

  Future<YktSession> _sessionFromResponse({
    required Map<String, dynamic> responseData,
    required Map<String, String> responseHeaders,
    required YktServer server,
    required String cookie,
    String phone = '',
  }) async {
    final parsedCookies = parseResponseCookies(
      responseHeaders,
      parseCookieString(cookie),
    );
    final mergedCookie = joinCookies(parsedCookies);
    final profile = await _fetchProfile(mergedCookie, server);
    final payload = responseData['data'] is Map
        ? Map<String, dynamic>.from(responseData['data'] as Map)
        : <String, dynamic>{};
    final userId =
        '${profile?['user_id'] ?? payload['user_id'] ?? payload['id'] ?? ''}';
    if (mergedCookie.isEmpty) {
      throw const YktApiException('雨课堂未返回有效登录凭据');
    }
    return YktSession(
      userId: userId.isNotEmpty
          ? userId
          : 'u_${DateTime.now().millisecondsSinceEpoch}',
      name: '${profile?['name'] ?? payload['name'] ?? '雨课堂学员'}',
      avatar: _secureUrl('${profile?['avatar'] ?? payload['avatar'] ?? ''}'),
      school: '${profile?['school'] ?? payload['school'] ?? ''}',
      server: server,
      cookie: mergedCookie,
      phoneNumber: phone,
    );
  }

  Future<Map<String, dynamic>?> _fetchProfile(
    String cookie,
    YktServer server,
  ) async {
    if (cookie.isEmpty) return null;
    try {
      final response = await _send(
        _client.get(
          _uri(server, '/v/course_meta/user_info'),
          headers: {
            'Cookie': cookie,
            'Accept': 'application/json',
            'Referer': '${server.domain}/',
          },
        ),
        timeout: const Duration(seconds: 8),
      );
      final data = await _decodeResponse(response);
      if (response.statusCode != 200 || data is! Map) return null;
      final root = data['data'] is Map
          ? Map<String, dynamic>.from(data['data'] as Map)
          : Map<String, dynamic>.from(data);
      final user = root['user_profile'] is Map
          ? Map<String, dynamic>.from(root['user_profile'] as Map)
          : root['user'] is Map
          ? Map<String, dynamic>.from(root['user'] as Map)
          : root;
      return {
        'user_id': '${user['user_id'] ?? user['id'] ?? ''}',
        'name': '${user['name'] ?? user['nickname'] ?? '雨课堂学员'}',
        'avatar': _secureUrl('${user['avatar'] ?? user['avatar_96'] ?? ''}'),
        'school':
            '${user['school'] ?? root['school_name'] ?? user['school_name'] ?? ''}',
      };
    } catch (_) {
      return null;
    }
  }

  Future<SessionValidation> validateSession(YktSession session) async {
    if (session.cookie.isEmpty) return SessionValidation.invalid;
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/v/course_meta/user_info'),
          headers: {
            'Cookie': session.cookie,
            'Accept': 'application/json',
            'Referer': '${session.server.domain}/',
          },
        ),
        timeout: const Duration(seconds: 8),
      );
      if (response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 302) {
        return SessionValidation.invalid;
      }
      final data = await _decodeResponse(response);
      if (response.statusCode != 200 || data is! Map) {
        return SessionValidation.unknown;
      }
      final payload = data['data'] is Map
          ? Map<String, dynamic>.from(data['data'] as Map)
          : Map<String, dynamic>.from(data);
      final code = int.tryParse('${data['code'] ?? payload['code'] ?? ''}');
      if (code == 401 || code == 50000 || code == 10001) {
        return SessionValidation.invalid;
      }
      if (code != null && code != 0) {
        return SessionValidation.invalid;
      }
      final profile = payload['user_profile'] is Map
          ? Map<String, dynamic>.from(payload['user_profile'] as Map)
          : payload['user'] is Map
          ? Map<String, dynamic>.from(payload['user'] as Map)
          : payload;
      final userId = '${profile['user_id'] ?? profile['id'] ?? ''}';
      return userId.isNotEmpty
          ? SessionValidation.valid
          : SessionValidation.invalid;
    } catch (_) {
      return SessionValidation.unknown;
    }
  }

  Future<List<YktLesson>> fetchOnLesson(YktSession session) async {
    final response = await _send(
      _client.get(
        _uri(session.server, '/api/v3/classroom/on-lesson'),
        headers: {
          'Cookie': session.cookie,
          'Accept': 'application/json',
          'Referer': '${session.server.domain}/lesson/fullscreen/v3/',
        },
      ),
      timeout: const Duration(seconds: 10),
    );
    final data = await _decodeResponse(response);
    if (response.statusCode == 401) {
      throw const YktApiException('雨课堂登录状态已过期', code: 401);
    }
    if (data is Map) {
      final code = int.tryParse('${data['code']}');
      final message = '${data['message'] ?? data['msg'] ?? '雨课堂登录状态已过期'}';
      if (code == 401 || code == 50000 || code == 10001) {
        throw YktApiException(message, code: code!);
      }
      if (code != null && code != 0) {
        throw YktApiException(message, code: code);
      }
    }
    if (response.statusCode != 200 || data is! Map) {
      throw YktApiException(_messageFrom(data, '获取正在上课列表失败'));
    }
    final payload = data['data'];
    if (payload is! Map) return const [];
    final lessons = payload['onLessonClassrooms'];
    if (lessons is! List) return const [];
    return lessons
        .whereType<Map>()
        .map((e) => YktLesson.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<CheckinResult> checkIn({
    required YktSession session,
    required YktLesson lesson,
  }) async {
    final cookieMap = parseCookieString(session.cookie);
    final headers = _mobileHeaders(
      session.server,
      cookie: session.cookie,
      userId: session.userId,
    );
    if (cookieMap['csrftoken'] case final token?) {
      headers['x-csrftoken'] = token;
    }
    if (cookieMap['sessionid'] case final token?) {
      headers['sessionid'] = token;
    }

    final response = await _send(
      _client.post(
        _uri(session.server, '/api/v3/lesson/checkin'),
        headers: headers,
        body: jsonEncode({
          'source': 21,
          'lessonId': lesson.id,
          'joinIfNotIn': true,
        }),
      ),
    );
    final data = await _decodeResponse(response);
    if (response.statusCode == 401) {
      throw const YktApiException('雨课堂登录状态已过期', code: 401);
    }
    if (data is! Map) {
      throw const YktApiException('进班签到返回格式异常');
    }
    final code = int.tryParse('${data['code']}') ?? -1;
    _debugLog(
      'checkin lesson=${lesson.id} status=${response.statusCode} code=$code '
      'hasSetAuth=${(response.headers['set-auth'] ?? '').isNotEmpty}',
    );
    if (code == 50070) {
      return const CheckinResult(code: 50070, message: '该课堂已开启动态二维码签到，请现场扫码');
    }
    if (code != 0) {
      return CheckinResult(code: code, message: _messageFrom(data, '进班签到失败'));
    }
    final payload = data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : <String, dynamic>{};
    final bearer =
        response.headers['set-auth'] ?? response.headers['Set-Auth'] ?? '';
    final lessonToken =
        '${payload['lessonToken'] ?? payload['lesson_token'] ?? ''}';
    final lessonInfo = await fetchLessonInfo(
      session: session,
      lessonId: lesson.id,
    );
    _debugLog(
      'checkin lesson=${lesson.id} presentations=${lessonInfo.presentations.length} '
      'active=${lessonInfo.activePresentationId}',
    );
    return CheckinResult(
      code: 0,
      message: '成功进入课堂',
      lessonToken: lessonToken,
      bearerToken: bearer,
      activePresentationId: lessonInfo.activePresentationId,
      presentations: lessonInfo.presentations,
    );
  }

  Future<LessonInfoResult> fetchLessonInfo({
    required YktSession session,
    required String lessonId,
    bool forceRefresh = false,
  }) async {
    final response = await _send(
      _client.get(
        _uri(session.server, '/v/lesson/lesson_info_v2', {
          'lesson_id': lessonId,
          if (forceRefresh) '_': '${DateTime.now().millisecondsSinceEpoch}',
        }),
        headers: {
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
          'Cookie': session.cookie,
          'Referer': '${session.server.domain}/lesson/fullscreen/v3/$lessonId',
        },
      ),
      timeout: const Duration(seconds: 10),
    );
    final data = await _decodeResponse(response);
    _debugLog(
      'lesson_info lesson=$lessonId status=${response.statusCode} '
      'shape=${data is Map ? data.keys.join(',') : data.runtimeType}',
    );
    if (response.statusCode != 200 || data is! Map) {
      return const LessonInfoResult();
    }
    final payload = data['data'];
    _debugLog(
      'lesson_info payload=${payload is Map ? payload.keys.join(',') : payload.runtimeType}',
    );
    if (payload is! Map) return const LessonInfoResult();
    final list = payload['presentationList'];
    final presentations = list is List
        ? list
              .whereType<Map>()
              .map(
                (e) =>
                    PresentationSummary.fromJson(Map<String, dynamic>.from(e)),
              )
              .where((e) => e.id.isNotEmpty)
              .toList()
        : <PresentationSummary>[];
    _debugLog(
      'lesson_info parsed presentations=${presentations.length} '
      'ids=${presentations.map((item) => item.id).join(',')}',
    );
    return LessonInfoResult(
      activePresentationId: presentations.isEmpty ? '' : presentations.first.id,
      presentations: presentations,
    );
  }

  Future<YktPresentation> fetchPresentation({
    required YktSession session,
    required String lessonId,
    String presentationId = '',
    String bearerToken = '',
    bool forceRefresh = false,
  }) async {
    var effectiveId = presentationId;
    if (effectiveId.isEmpty) {
      final info = await fetchLessonInfo(
        session: session,
        lessonId: lessonId,
        forceRefresh: forceRefresh,
      );
      effectiveId = info.activePresentationId;
    }
    if (effectiveId.isEmpty) {
      return const YktPresentation(
        id: '',
        title: '课堂课件',
        slides: [],
        empty: true,
      );
    }
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/api/v3/lesson/presentation/fetch', {
            'presentation_id': effectiveId,
            if (forceRefresh) '_': '${DateTime.now().millisecondsSinceEpoch}',
          }),
          headers: {
            'Accept': 'application/json',
            'Cache-Control': 'no-cache',
            'Pragma': 'no-cache',
            'Referer': '${session.server.domain}/lesson/fullscreen/v3/',
            if (bearerToken.isNotEmpty) 'Authorization': 'Bearer $bearerToken',
            'Cookie': session.cookie,
          },
        ),
        timeout: const Duration(seconds: 10),
      );
      final data = await _decodeResponse(response);
      if (kDebugMode &&
          data is Map &&
          data['data'] is Map &&
          (data['data'] as Map)['slides'] is List) {
        final slides = (data['data'] as Map)['slides'] as List;
        final samples = slides
            .take(5)
            .map((slide) {
              if (slide is! Map) return '${slide.runtimeType}';
              final cover = '${slide['cover'] ?? slide['cover_url'] ?? ''}';
              final path = Uri.tryParse(cover)?.path ?? cover;
              return 'id=${slide['id'] ?? slide['slide_id'] ?? ''} '
                  'index=${slide['index'] ?? slide['page'] ?? ''} '
                  'cover=$path';
            })
            .join(' | ');
        _debugLog('slides sample: $samples');
      }
      _debugLog(
        'presentation direct id=$effectiveId status=${response.statusCode} '
        'code=${data is Map ? data['code'] : '-'} '
        'slides=${data is Map && data['data'] is Map && (data['data'] as Map)['slides'] is List ? ((data['data'] as Map)['slides'] as List).length : -1}',
      );
      if (response.statusCode == 200 &&
          data is Map &&
          int.tryParse('${data['code']}') == 0 &&
          data['data'] is Map) {
        return YktPresentation.fromJson(
          Map<String, dynamic>.from(data['data'] as Map),
        );
      }
    } catch (_) {
      // Try the relay after direct failure.
    }

    try {
      final response = await _send(
        _client.post(
          _gateway('/api/ykt/lesson/presentation'),
          headers: {
            'Content-Type': 'application/json',
            if (bearerToken.isNotEmpty) 'X-Ykt-Bearer-Token': bearerToken,
            'X-Ykt-Cookie': session.cookie,
            'X-Ykt-User-Id': session.userId,
          },
          body: jsonEncode({
            'user_id': session.userId,
            'presentation_id': effectiveId,
            'lesson_id': lessonId,
            'server': session.server.id,
            'bearer_token': bearerToken,
            'cookie': session.cookie,
          }),
        ),
        timeout: const Duration(seconds: 15),
      );
      final data = await _decodeResponse(response);
      _debugLog(
        'presentation relay id=$effectiveId status=${response.statusCode} '
        'code=${data is Map ? data['code'] : '-'}',
      );
      if (response.statusCode == 200 &&
          data is Map &&
          int.tryParse('${data['code']}') == 0 &&
          data['data'] is Map) {
        return YktPresentation.fromJson(
          Map<String, dynamic>.from(data['data'] as Map),
        );
      }
    } catch (_) {}
    return const YktPresentation(
      id: '',
      title: '课堂课件',
      slides: [],
      empty: true,
    );
  }

  Future<AnswerSubmitResult> submitAnswer({
    required YktSession session,
    required String lessonId,
    required String problemId,
    required int problemType,
    required Object result,
    required int problemDt,
    required bool retry,
    String bearerToken = '',
  }) async {
    if (bearerToken.isEmpty) {
      return _submitViaGateway(
        session: session,
        lessonId: lessonId,
        problemId: problemId,
        problemType: problemType,
        answer: result,
        problemDt: problemDt,
        retry: retry,
      );
    }
    try {
      final direct = await _submitDirect(
        session: session,
        problemId: problemId,
        problemType: problemType,
        answer: result,
        problemDt: problemDt,
        retry: retry,
        bearerToken: bearerToken,
      );
      return direct;
    } catch (_) {
      return _submitViaGateway(
        session: session,
        lessonId: lessonId,
        problemId: problemId,
        problemType: problemType,
        answer: result,
        problemDt: problemDt,
        retry: retry,
      );
    }
  }

  Future<AnswerSubmitResult> _submitDirect({
    required YktSession session,
    required String problemId,
    required int problemType,
    required Object answer,
    required int problemDt,
    required bool retry,
    required String bearerToken,
  }) async {
    final path = retry
        ? '/api/v3/lesson/problem/retry'
        : '/api/v3/lesson/problem/answer';
    final dt = problemDt > 100000000000 ? problemDt ~/ 1000 : problemDt;
    final body = retry
        ? {
            'problems': [
              {
                'problemId': problemId,
                'dt': dt,
                'problemType': problemType,
                'result': answer,
                'retry_times': null,
              },
            ],
          }
        : {
            'problemId': problemId,
            'dt': dt,
            'problemType': problemType,
            'result': answer,
          };
    final response = await _send(
      _client.post(
        _uri(session.server, path),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $bearerToken',
          'Referer': '${session.server.domain}/',
          'Cookie': session.cookie,
        },
        body: jsonEncode(body),
      ),
      timeout: const Duration(seconds: 12),
    );
    final data = await _decodeResponse(response);
    final code = data is Map
        ? int.tryParse('${data['code']}') ?? response.statusCode
        : response.statusCode;
    if (code == 0) {
      return AnswerSubmitResult(
        success: true,
        message: retry ? '补交成功' : '作答提交成功',
      );
    }
    if (code == 50028) {
      return AnswerSubmitResult(
        success: false,
        code: code,
        message: '该题目已在其他客户端完成作答',
      );
    }
    return AnswerSubmitResult(
      success: false,
      code: code,
      message: _messageFrom(data, retry ? '补交失败' : '提交作答失败'),
    );
  }

  Future<AnswerSubmitResult> _submitViaGateway({
    required YktSession session,
    required String lessonId,
    required String problemId,
    required int problemType,
    required Object answer,
    required int problemDt,
    required bool retry,
  }) async {
    try {
      final response = await _send(
        _client.post(
          _gateway('/api/ykt/lesson/answer'),
          headers: {
            'Content-Type': 'application/json',
            'X-Ykt-Cookie': session.cookie,
            'X-Ykt-User-Id': session.userId,
          },
          body: jsonEncode({
            'user_id': session.userId,
            'problem_id': problemId,
            'lesson_id': lessonId,
            'problem_type': problemType,
            'result': answer,
            'problem_dt': problemDt,
            'retry': retry,
            'server': session.server.id,
            'bearer_token': '',
            'cookie': session.cookie,
          }),
        ),
        timeout: const Duration(seconds: 15),
      );
      final data = await _decodeResponse(response);
      if (data is Map) {
        final code = int.tryParse('${data['code']}') ?? -1;
        final ok = code == 0 || data['success'] == true;
        return AnswerSubmitResult(
          success: ok,
          code: code,
          message: _messageFrom(data, ok ? '作答提交成功' : '作答提交失败'),
        );
      }
    } catch (_) {}
    return const AnswerSubmitResult(success: false, message: '雨课堂答题网络异常');
  }

  Future<UploadedAnswerImage> uploadAnswerImage({
    required YktSession session,
    required XFile file,
  }) async {
    final token = await _getQiniuToken(session);
    final bytes = await file.readAsBytes();
    final rawName = file.name;
    final dotIndex = rawName.lastIndexOf('.');
    final extension = (dotIndex != -1 && dotIndex < rawName.length - 1)
        ? rawName.substring(dotIndex + 1).toLowerCase()
        : 'jpg';
    final mimeType = switch (extension) {
      'png' => 'png',
      'webp' => 'webp',
      'gif' => 'gif',
      'bmp' => 'bmp',
      _ => 'jpeg',
    };
    final key =
        '${DateTime.now().millisecondsSinceEpoch}_${_randomString(6)}.$extension';
    final request =
        http.MultipartRequest('POST', Uri.parse('https://upload.qiniup.com/'))
          ..fields['token'] = token
          ..fields['key'] = key
          ..fields['fname'] = key
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: key,
              contentType: MediaType('image', mimeType),
            ),
          );
    final streamed = await request.send().timeout(const Duration(seconds: 35));
    final response = await http.Response.fromStream(streamed);
    final data = await _decodeResponse(response);
    if (response.statusCode != 200 || data is! Map || data['key'] == null) {
      throw YktApiException(_messageFrom(data, '图片上传失败'));
    }
    final pic = 'https://qn-scd1.yuketang.cn/${data['key']}';
    return UploadedAnswerImage(pic: pic, thumb: '$pic?imageView2/2/w/568');
  }

  Future<String> _getQiniuToken(YktSession session) async {
    Future<String?> requestToken(YktServer server) async {
      try {
        final response = await _send(
          _client.post(
            _uri(server, qiniuTokenPath),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'Referer': '${server.domain}/',
              'Cookie': session.cookie,
            },
            body: jsonEncode({
              'bucket_name': qiniuBucket,
              'expired_time': 3600,
            }),
          ),
          timeout: const Duration(seconds: 12),
        );
        final data = await _decodeResponse(response);
        if (data is Map) {
          final payload = data['data'];
          if (payload is Map && payload['token'] != null) {
            return '${payload['token']}';
          }
          if (data['token'] != null) return '${data['token']}';
        }
      } catch (_) {}
      return null;
    }

    final token =
        await requestToken(session.server) ??
        await requestToken(YktServer.yuketang);
    if (token == null || token.isEmpty) {
      throw const YktApiException('获取七牛上传凭证失败');
    }
    return token;
  }

  String _getDeviceId() {
    return _deviceId ??= List.generate(
      32,
      (_) => Random.secure().nextInt(16).toRadixString(16),
    ).join();
  }

  void _rememberResponseCookie(http.Response response) {
    final cookies = parseResponseCookies(
      response.headers,
      parseCookieString(_tempCookie),
    );
    _tempCookie = joinCookies(cookies);
  }

  String _messageFrom(Object? data, String fallback) {
    if (data is Map) {
      return '${data['msg'] ?? data['message'] ?? data['error'] ?? fallback}';
    }
    return fallback;
  }

  String _secureUrl(String url) {
    return url.startsWith('http://')
        ? url.replaceFirst('http://', 'https://')
        : url;
  }

  String _randomString(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return List.generate(
      length,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  Future<List<YktCourse>> fetchMyCourses(YktSession session) async {
    final headers = {
      ..._mobileHeaders(
        session.server,
        cookie: session.cookie,
        userId: session.userId,
      ),
      'Referer': '${session.server.domain}/v2/web/index',
    };

    // 优先使用 v2 学生课程列表接口
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/v2/api/web/courses/list', {'identity': '2'}),
          headers: headers,
        ),
        timeout: const Duration(seconds: 10),
      );
      if (response.statusCode == 401) {
        throw const YktApiException('雨课堂登录状态已过期', code: 401);
      }
      _debugLog('fetchMyCourses status=${response.statusCode} len=${response.body.length}');
      final data = await _decodeResponse(response);
      if (data is Map && (int.tryParse('${data['errcode'] ?? data['code'] ?? 0}') ?? -1) == 0) {
        final payload = data['data'];
        final rawList = payload is Map ? (payload['list'] ?? payload['courses']) : payload;
        if (rawList is List && rawList.isNotEmpty) {
          _debugLog('fetchMyCourses parsed ${rawList.length} courses');
          return rawList
              .whereType<Map>()
              .map((item) => YktCourse.fromJson(Map<String, dynamic>.from(item)))
              .where((c) => c.classroomId.isNotEmpty)
              .toList();
        }
      } else {
        _debugLog('fetchMyCourses unexpected data: ${response.body.substring(0, min(200, response.body.length))}');
      }
    } catch (e) {
      _debugLog('fetchMyCourses error: $e');
      if (e is YktApiException && e.code == 401) rethrow;
    }

    // 备选回退 /api/my_course
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/api/my_course'),
          headers: headers,
        ),
        timeout: const Duration(seconds: 10),
      );
      final data = await _decodeResponse(response);
      if (data is Map) {
        final payload = data['data'] ?? data;
        final rawList = payload is Map ? (payload['list'] ?? payload['courses']) : payload;
        if (rawList is List) {
          return rawList
              .whereType<Map>()
              .map((item) => YktCourse.fromJson(Map<String, dynamic>.from(item)))
              .where((c) => c.classroomId.isNotEmpty)
              .toList();
        }
      }
    } catch (_) {}

    return const [];
  }

  Future<List<YktHomeworkTask>> fetchCourseHomeworks(
    YktSession session,
    YktCourse course,
  ) async {
    final headers = {
      ..._mobileHeaders(
        session.server,
        cookie: session.cookie,
        userId: session.userId,
      ),
      'Referer': '${session.server.domain}/v2/web/studentLog/${course.classroomId}',
    };
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/v2/api/web/logs/learn/${course.classroomId}', {
            'actype': '-1',
            'page': '0',
            'offset': '40',
            'sort': '-1',
          }),
          headers: headers,
        ),
        timeout: const Duration(seconds: 10),
      );
      final data = await _decodeResponse(response);
      if (data is! Map || data['data'] is! Map) {
        _debugLog('fetchCourseHomeworks(${course.courseName}) status=${response.statusCode} body=${response.body.substring(0, min(180, response.body.length))}');
        return const [];
      }
      final payload = data['data'] as Map;
      final activities = payload['activities'] ?? payload['list'];
      if (activities is! List) return const [];

      final tasks = <YktHomeworkTask>[];
      for (final raw in activities.whereType<Map>()) {
        final item = Map<String, dynamic>.from(raw);
        final type = int.tryParse('${item['type'] ?? -1}') ?? -1;
        final coursewareType = '${item['courseware_type'] ?? ''}'.toLowerCase();
        // type == 5 (作业/试卷), type == 15 或 type == 6, 或者标记为 homework / exercise
        final isHomework = type == 5 ||
            type == 15 ||
            type == 6 ||
            coursewareType.contains('homework') ||
            coursewareType.contains('exercise');
        if (!isHomework) continue;

        final id = '${item['courseware_id'] ?? item['id'] ?? item['activity_id'] ?? ''}';
        if (id.isEmpty) continue;

        final title = '${item['title'] ?? item['name'] ?? '未命名作业'}';
        final deadlineRaw = item['deadline'] ?? item['end_time'] ?? item['endTime'] ?? item['limit'];
        final deadline = _parseDateTime(deadlineRaw);
        final startRaw = item['create_time'] ?? item['start_time'] ?? item['publish_time'];
        final startTime = _parseDateTime(startRaw);

        // /v2/api/web/logs/learn 中 type==5 的 status=1 表示进行中/未提交，status>=2 表示已提交或已结束；
        // 若接口显式返回 submit_status，则 0=未提交，1/2=已提交，>=3=已批改。
        final hasSubmitStatus = item['submit_status'] != null;
        final submitStatusRaw = int.tryParse('${item['submit_status'] ?? 0}') ?? 0;
        final activityStatusRaw = int.tryParse('${item['status'] ?? 0}') ?? 0;
        final rawScore = (item['score'] as num?)?.toDouble();
        final rawTotal = (item['total_score'] as num?)?.toDouble();
        final totalScore = (rawTotal != null && rawTotal > 0) ? rawTotal : null;
        final isGraded = (hasSubmitStatus ? submitStatusRaw >= 3 : activityStatusRaw >= 3) ||
            (item['is_graded'] == true) ||
            (rawScore != null && rawScore > 0 && (hasSubmitStatus ? submitStatusRaw >= 1 : activityStatusRaw >= 2));
        final isSubmitted = (hasSubmitStatus ? submitStatusRaw >= 1 : activityStatusRaw >= 2) ||
            item['has_submitted'] == true ||
            isGraded;
        final isOverdue = !isSubmitted && deadline != null && deadline.isBefore(DateTime.now());
        final score = (isGraded && rawScore != null && rawScore >= 0) ? rawScore : null;

        final status = isGraded
            ? HomeworkStatus.graded
            : isSubmitted
                ? HomeworkStatus.submitted
                : isOverdue
                    ? HomeworkStatus.overdue
                    : HomeworkStatus.unsubmitted;

        final allowOverdue = item['allow_overdue'] == true ||
            item['allow_overdue_submit'] == true ||
            item['overdue_submit'] == true;
        final overdueRate = (item['overdue_score_rate'] as num?)?.toDouble();

        tasks.add(
          YktHomeworkTask(
            id: '${course.classroomId}_$id',
            classroomId: course.classroomId,
            courseName: course.courseName,
            title: title,
            status: status,
            startTime: startTime,
            deadline: deadline,
            allowOverdueSubmit: allowOverdue,
            overdueScoreRate: overdueRate,
            score: score,
            totalScore: totalScore,
            webUrl: '${session.server.domain}/v2/web/student/homework/${course.classroomId}/$id',
          ),
        );
      }
      return tasks;
    } catch (e) {
      _debugLog('fetchCourseHomeworks(${course.courseName}) err=$e');
      return const [];
    }
  }

  Future<List<YktHomeworkTask>> fetchUpcomingExams(YktSession session) async {
    try {
      final response = await _send(
        _client.get(
          _uri(session.server, '/api/v3/classroom/on-lesson-upcoming-exam'),
          headers: _mobileHeaders(
            session.server,
            cookie: session.cookie,
            userId: session.userId,
          ),
        ),
        timeout: const Duration(seconds: 8),
      );
      final data = await _decodeResponse(response);
      if (data is! Map || data['data'] is! Map) {
        return const [];
      }
      final payload = data['data'] as Map;
      final exams = payload['upcomingExams'] ?? payload['exams'] ?? payload['list'];
      if (exams is! List) return const [];

      final tasks = <YktHomeworkTask>[];
      for (final raw in exams.whereType<Map>()) {
        final item = Map<String, dynamic>.from(raw);
        final id = '${item['examId'] ?? item['id'] ?? ''}';
        if (id.isEmpty) continue;
        final classroomId = '${item['classroomId'] ?? item['classroom_id'] ?? ''}';
        tasks.add(
          YktHomeworkTask(
            id: 'exam_$id',
            classroomId: classroomId,
            courseName: '${item['courseName'] ?? item['classroomName'] ?? '线上测验'}',
            title: '${item['title'] ?? item['name'] ?? '随堂考试'}',
            status: HomeworkStatus.unsubmitted,
            startTime: _parseDateTime(item['startTime']),
            deadline: _parseDateTime(item['endTime'] ?? item['deadline']),
            isExam: true,
          ),
        );
      }
      return tasks;
    } catch (_) {
      return const [];
    }
  }

  Future<List<YktHomeworkTask>> fetchAllHomeworkTasks(YktSession session) async {
    final results = await Future.wait([
      fetchMyCourses(session),
      fetchUpcomingExams(session),
    ]);
    final courses = results[0] as List<YktCourse>;
    final exams = results[1] as List<YktHomeworkTask>;

    final allTasks = <YktHomeworkTask>[...exams];

    // 受控并发，每次最多拉取 8 个课程班级，防止并发过高触发限流
    const batchSize = 8;
    for (var i = 0; i < courses.length; i += batchSize) {
      final batch = courses.skip(i).take(batchSize);
      final batchResults = await Future.wait(
        batch.map((c) => fetchCourseHomeworks(session, c)),
      );
      for (final list in batchResults) {
        allTasks.addAll(list);
      }
    }

    // 去重并按紧急度排序
    final uniqueById = <String, YktHomeworkTask>{};
    for (final task in allTasks) {
      uniqueById[task.id] = task;
    }
    final sorted = uniqueById.values.toList()
      ..sort((a, b) {
        // 未提交的排前面，已完成和已逾期排后面
        if (a.isCompleted != b.isCompleted) {
          return a.isCompleted ? 1 : -1;
        }
        if (a.status == HomeworkStatus.overdue && b.status != HomeworkStatus.overdue) {
          return 1;
        }
        if (b.status == HomeworkStatus.overdue && a.status != HomeworkStatus.overdue) {
          return -1;
        }
        final ad = a.deadline;
        final bd = b.deadline;
        if (ad != null && bd != null) return ad.compareTo(bd);
        if (ad != null) return -1;
        if (bd != null) return 1;
        return a.title.compareTo(b.title);
      });

    return sorted;
  }

  DateTime? _parseDateTime(Object? raw) {
    if (raw == null) return null;
    if (raw is int) {
      if (raw <= 0) return null;
      // 区分秒级和毫秒级时间戳
      final ms = raw < 100000000000 ? raw * 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String && raw.trim().isNotEmpty) {
      final numVal = int.tryParse(raw.trim());
      if (numVal != null) return _parseDateTime(numVal);
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  void dispose() => _client.close();
}

class QrLoginInfo {
  const QrLoginInfo({
    required this.token,
    required this.qrContent,
    required this.qrImage,
  });

  final String token;
  final String qrContent;
  final String qrImage;
}

enum QrPollState { waiting, success, expired }

class QrPollResult {
  const QrPollResult({required this.state, this.session});

  final QrPollState state;
  final YktSession? session;
}

class LessonInfoResult {
  const LessonInfoResult({
    this.activePresentationId = '',
    this.presentations = const [],
  });

  final String activePresentationId;
  final List<PresentationSummary> presentations;
}

enum SessionValidation { valid, invalid, unknown }
