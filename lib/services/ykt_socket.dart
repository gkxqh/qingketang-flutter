import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/io.dart';

import '../models/classroom_event.dart';
import '../models/ykt_session.dart';

class YktSocket {
  YktSocket._(this._channel);

  final IOWebSocketChannel _channel;
  final _events = StreamController<ClassroomEvent>.broadcast();
  Timer? _heartbeat;
  bool _closed = false;

  Stream<ClassroomEvent> get events => _events.stream;

  static YktSocket connect({
    required YktSession session,
    required String lessonId,
    required String lessonToken,
  }) {
    final channel = IOWebSocketChannel.connect(
      Uri.parse(session.server.socketUrl),
      headers: {
        'Origin': session.server.domain,
        'Referer': '${session.server.domain}/lesson/fullscreen/v3/',
        'Cookie': session.cookie,
        'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/115.0 Mobile Safari/537.36',
      },
      pingInterval: const Duration(seconds: 20),
      connectTimeout: const Duration(seconds: 10),
    );
    final socket = YktSocket._(channel);
    socket._listen();
    channel.ready
        .then((_) {
          if (socket._closed) return;
          socket.send({
            'op': 'hello',
            'userid': session.userId,
            'avatar': session.avatar,
            'role': 'student',
            'auth': lessonToken,
            'lessonid': lessonId,
            'ver': 1,
          });
          socket._startHeartbeat(lessonId);
        })
        .catchError((Object error) {
          if (!socket._closed) {
            socket._events.addError(error);
          }
        });
    return socket;
  }

  void _listen() {
    _channel.stream.listen(
      (data) {
        try {
          final decoded = jsonDecode('$data');
          if (decoded is Map) {
            final payload = Map<String, dynamic>.from(decoded);
            final op = '${payload['op'] ?? ''}';
            _events.add(
              ClassroomEvent(
                op: op,
                payload: payload,
                receivedAt: DateTime.now(),
              ),
            );
          }
        } catch (_) {
          // Ignore malformed server frames instead of closing the classroom.
        }
      },
      onError: (Object error) {
        _heartbeat?.cancel();
        if (!_events.isClosed) _events.addError(error);
      },
      onDone: () {
        _heartbeat?.cancel();
        if (!_events.isClosed) _events.close();
      },
      cancelOnError: false,
    );
  }

  void _startHeartbeat(String lessonId) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
      send({'op': 'heartbeat', 'lessonid': lessonId});
    });
  }

  void send(Map<String, dynamic> payload) {
    if (_closed) return;
    _channel.sink.add(jsonEncode(payload));
  }

  Future<void> close({String? lessonId}) async {
    if (_closed) return;
    if (lessonId != null && lessonId.isNotEmpty) {
      send({'op': 'leavelesson', 'lessonid': lessonId});
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _closed = true;
    _heartbeat?.cancel();
    await _channel.sink.close();
    if (!_events.isClosed) await _events.close();
  }
}
