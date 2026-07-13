import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import 'call_service.dart';

class SignalEvent {
  final String type;
  final Map<String, dynamic> data;

  const SignalEvent(this.type, this.data);
}

class SignalService with WidgetsBindingObserver {
  SignalService._();

  static final SignalService instance = SignalService._();

  static const String _baseUrl = 'https://fenghuomixin.online';
  static const String _wsUrl = 'wss://fenghuomixin.online/ws';
  static const MethodChannel _windowsSystemSoundChannel = MethodChannel(
    'fenghuo/windows_system_sound',
  );

  final StreamController<SignalEvent> _eventsController =
      StreamController<SignalEvent>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _connecting = false;
  bool _lifecycleBound = false;
  AppLifecycleState? _appState;
  FlutterLocalNotificationsPlugin? _notifier;
  Map<String, dynamic>? _pendingNotificationPayload;

  int? _userId;
  String? _token;
  final Map<int, int> _unreadByPeer = <int, int>{};
  final Map<int, String> _lastMessageByPeer = <int, String>{};
  final Map<int, String> _lastTimeByPeer = <int, String>{};
  final Map<int, String> _nicknameByPeer = <int, String>{};
  final Map<int, String> _avatarByPeer = <int, String>{};
  final Map<int, String> _remarkByPeer = <int, String>{};
  String _remarksLoadedKey = '';
  bool _remarksLoading = false;
  int _friendRequestCount = 0;
  int? _activePeerId;
  final Rxn<Map<String, dynamic>> callOverlay = Rxn<Map<String, dynamic>>();

  Stream<SignalEvent> listen() => _eventsController.stream;

  void showCallOverlay({
    required int peerId,
    required String peerName,
    required String callId,
    required String channelId,
    int? startedAtMs,
  }) {
    callOverlay.value = <String, dynamic>{
      'peerId': peerId,
      'peerName': peerName,
      'callId': callId,
      'channelId': channelId,
      'startedAtMs': startedAtMs ?? DateTime.now().millisecondsSinceEpoch,
    };
  }

  void clearCallOverlay() {
    callOverlay.value = null;
  }

  bool _isForeground() {
    return _appState == AppLifecycleState.resumed;
  }

  Future<void> _playWindowsSystemMessageBeep() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _windowsSystemSoundChannel.invokeMethod<void>('playMessageBeep');
    } catch (_) {}
  }

  Future<void> _flashWindowsTaskbar() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    if (_isForeground()) return;
    try {
      await _windowsSystemSoundChannel.invokeMethod<void>('flashWindow');
    } catch (_) {}
  }

  Future<void> initLocalNotifications() async {
    if (kIsWeb) return;
    if (_notifier != null) return;
    final FlutterLocalNotificationsPlugin plugin =
        FlutterLocalNotificationsPlugin();

    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const DarwinInitializationSettings iosInit = DarwinInitializationSettings();
    const InitializationSettings initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );

    await plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final String? raw = response.payload;
        if (raw == null || raw.trim().isEmpty) return;
        try {
          final dynamic decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            _pendingNotificationPayload = decoded;
            Future.microtask(_consumePendingNotificationPayload);
          }
        } catch (_) {}
      },
    );

    try {
      await plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {}
    try {
      await plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {}

    _notifier = plugin;
  }

  void _consumePendingNotificationPayload() {
    final Map<String, dynamic>? p = _pendingNotificationPayload;
    if (p == null) return;
    _pendingNotificationPayload = null;
    try {
      final String type = (p['type'] ?? '').toString();
      if (type == 'message') {
        final int? peerId = int.tryParse((p['peerId'] ?? '').toString());
        final String peerName = (p['peerName'] ?? '').toString();
        if (peerId == null) return;
        Get.toNamed(
          '/chat',
          parameters: {
            'peerId': peerId.toString(),
            'peerUsername': peerName.isNotEmpty ? peerName : peerId.toString(),
          },
        );
      } else if (type == 'call') {
        final int? peerId = int.tryParse((p['peerId'] ?? '').toString());
        final String peerName = (p['peerName'] ?? '').toString();
        final String callId = (p['callId'] ?? '').toString();
        final String channelId = (p['channelId'] ?? '').toString();
        if (peerId == null || callId.isEmpty || channelId.isEmpty) return;
        if (Get.currentRoute == '/call') return;
        Get.toNamed(
          '/call',
          arguments: {
            'peerId': peerId,
            'peerUsername': peerName.isNotEmpty ? peerName : peerId.toString(),
            'callId': callId,
            'channelId': channelId,
            'direction': 'incoming',
          },
        );
      }
    } catch (_) {}
  }

  String _normalizePreviewText(String text) {
    final String t = text.trim();
    if (t.isEmpty) return '';
    if (t == '[拍照]') return '拍照';
    if (t == '[图片]') return '图片';
    if (t.startsWith('data:image/') && t.contains(';base64,')) return '图片';
    final Uri? uri = Uri.tryParse(t);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final String lower = uri.path.toLowerCase();
      if (lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.heic')) {
        return '图片';
      }
    }
    final String lower = t.toLowerCase();
    if ((t.startsWith('/') || t.startsWith('file://')) &&
        (lower.endsWith('.jpg') ||
            lower.endsWith('.jpeg') ||
            lower.endsWith('.png') ||
            lower.endsWith('.gif') ||
            lower.endsWith('.webp') ||
            lower.endsWith('.heic'))) {
      return '图片';
    }
    return t;
  }

  Future<void> _showMessageNotification({
    required int peerId,
    required String title,
    required String body,
  }) async {
    final FlutterLocalNotificationsPlugin? plugin = _notifier;
    if (plugin == null) return;
    final String payload = jsonEncode({
      'type': 'message',
      'peerId': peerId,
      'peerName': title,
    });

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'messages',
          '消息',
          channelDescription: '聊天消息提醒',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
        );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBadge: true,
    );
    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    final String safeBody = body.length > 80
        ? '${body.substring(0, 80)}…'
        : body;
    await plugin.show(peerId, title, safeBody, details, payload: payload);
  }

  Future<void> _showIncomingCallNotification({
    required int peerId,
    required String peerName,
    required String callId,
    required String channelId,
  }) async {
    final FlutterLocalNotificationsPlugin? plugin = _notifier;
    if (plugin == null) return;
    final String payload = jsonEncode({
      'type': 'call',
      'peerId': peerId,
      'peerName': peerName,
      'callId': callId,
      'channelId': channelId,
    });

    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'calls',
          '来电',
          channelDescription: '语音来电提醒',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          fullScreenIntent: true,
          category: AndroidNotificationCategory.call,
        );
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      presentBadge: true,
    );
    const NotificationDetails details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await plugin.show(
      1000000 + peerId,
      '语音来电',
      peerName,
      details,
      payload: payload,
    );
  }

  int totalUnread() {
    int sum = 0;
    for (final v in _unreadByPeer.values) {
      sum += v;
    }
    return sum;
  }

  int friendRequestCount() {
    return _friendRequestCount;
  }

  int unreadForPeer(int peerId) {
    return _unreadByPeer[peerId] ?? 0;
  }

  String lastMessageForPeer(int peerId) {
    return _lastMessageByPeer[peerId] ?? '';
  }

  String lastTimeForPeer(int peerId) {
    return _lastTimeByPeer[peerId] ?? '';
  }

  String nicknameForPeer(int peerId) {
    return _nicknameByPeer[peerId] ?? '';
  }

  String avatarForPeer(int peerId) {
    return _avatarByPeer[peerId] ?? '';
  }

  String displayNameForPeer(int peerId, {String fallback = ''}) {
    final String r = (_remarkByPeer[peerId] ?? '').trim();
    if (r.isNotEmpty) return r;
    final String n = (_nicknameByPeer[peerId] ?? '').trim();
    if (n.isNotEmpty) return n;
    return fallback;
  }

  String remarkForPeer(int peerId) {
    return _remarkByPeer[peerId] ?? '';
  }

  Future<void> _ensureRemarksLoaded({
    required int userId,
    required String token,
  }) async {
    final String key = '$userId|${token.length}|${token.hashCode}';
    if (_remarksLoadedKey == key) return;
    if (_remarksLoading) return;
    _remarksLoading = true;
    try {
      final Uri url = Uri.parse('$_baseUrl/api/user/remarks');
      final http.Response res = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 401) return;
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> list = decoded is Map<String, dynamic>
          ? (decoded['remarks'] as List<dynamic>? ?? const [])
          : const [];
      final Map<int, String> next = <int, String>{};
      for (final item in list) {
        if (item is! Map) continue;
        final int? peerId = int.tryParse(
          (item['peerId'] ?? item['peer_id'] ?? '').toString(),
        );
        if (peerId == null) continue;
        final String remark = (item['remark'] ?? '').toString().trim();
        if (remark.isEmpty) continue;
        next[peerId] = remark;
      }
      _remarkByPeer
        ..clear()
        ..addAll(next);
      _remarksLoadedKey = key;
    } catch (_) {
    } finally {
      _remarksLoading = false;
    }
  }

  Future<void> setRemark({required int peerId, required String remark}) async {
    final int? userId = _userId;
    final String? token = _token;
    if (userId == null || token == null || token.isEmpty) return;
    final String trimmed = remark.trim();
    if (trimmed.length > 30) {
      throw Exception('备注最多 30 个字');
    }
    final Uri url = Uri.parse('$_baseUrl/api/user/remark');
    final http.Response res = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'peerId': peerId, 'remark': trimmed}),
    );
    if (res.statusCode == 401) return;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('保存失败');
    }
    if (trimmed.isEmpty) {
      _remarkByPeer.remove(peerId);
    } else {
      _remarkByPeer[peerId] = trimmed;
    }
  }

  void setActivePeer(int? peerId) {
    _activePeerId = peerId;
  }

  void updateConversationSnapshot({
    required int peerId,
    String? lastMessage,
    String? lastTime,
    int? unreadCount,
  }) {
    if (lastMessage != null) _lastMessageByPeer[peerId] = lastMessage;
    if (lastTime != null) _lastTimeByPeer[peerId] = lastTime;
    if (unreadCount != null) {
      _unreadByPeer[peerId] = unreadCount < 0 ? 0 : unreadCount;
    }
    _syncUnreadBadge();
  }

  void setUnreadSnapshot(Map<int, int> snapshot) {
    _unreadByPeer
      ..clear()
      ..addAll(snapshot.map((k, v) => MapEntry(k, v < 0 ? 0 : v)));
    _syncUnreadBadge();
  }

  int clearUnreadForPeer(int peerId) {
    final int removed = _unreadByPeer.remove(peerId) ?? 0;
    if (removed > 0) {
      _syncUnreadBadge();
    }
    return removed;
  }

  void _syncUnreadBadge() {
    try {
      final RxInt unread = Get.find<RxInt>(tag: 'homeUnreadCount');
      unread.value = totalUnread();
    } catch (_) {}
  }

  void _syncFriendRequestBadge() {
    try {
      final RxInt cnt = Get.find<RxInt>(tag: 'homeFriendRequestCount');
      cnt.value = _friendRequestCount;
    } catch (_) {}
  }

  void setFriendRequestCount(int count) {
    final int next = count < 0 ? 0 : count;
    if (_friendRequestCount == next) return;
    _friendRequestCount = next;
    _syncFriendRequestBadge();
  }

  Future<void> connect() async {
    if (!_lifecycleBound) {
      WidgetsBinding.instance.addObserver(this);
      _lifecycleBound = true;
      _appState ??=
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    }

    if (_connecting) return;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? userId = (int.tryParse((prefs.get('userId') ?? '').toString()));
    final String? token = prefs.getString('token');
    if (userId == null || token == null || token.isEmpty) {
      await disconnect();
      return;
    }

    try {
      await _ensureRemarksLoaded(userId: userId, token: token);
    } catch (_) {}

    if (_channel != null && _userId == userId && _token == token) return;

    _connecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await disconnect();
    _userId = userId;
    _token = token;

    try {
      final WebSocketChannel channel = WebSocketChannel.connect(
        Uri.parse(_wsUrl),
      );
      _channel = channel;
      channel.sink.add(
        jsonEncode({'type': 'auth', 'userId': userId, 'token': token}),
      );

      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        final WebSocketChannel? c = _channel;
        if (c == null) return;
        try {
          c.sink.add('{"type":"ping"}');
        } catch (_) {}
      });

      _sub = channel.stream.listen(
        (message) {
          try {
            final dynamic decoded = jsonDecode(message.toString());
            if (decoded is! Map<String, dynamic>) return;
            final String type = (decoded['type'] ?? '').toString();
            if (type.isEmpty) return;
            if (type == 'authed') {
              debugPrint('SignalService connected');
            } else if (type == 'pong') {
            } else if (type == 'call' ||
                type == 'incoming_call' ||
                type == 'incoming' ||
                type == 'call_offer') {
              final int? fromId = int.tryParse(
                (decoded['fromId'] ??
                        decoded['fromUserId'] ??
                        decoded['from_id'] ??
                        '')
                    .toString(),
              );
              final String callId =
                  (decoded['callId'] ??
                          decoded['call_id'] ??
                          decoded['id'] ??
                          '')
                      .toString();
              final String channelId =
                  (decoded['channelId'] ??
                          decoded['channel'] ??
                          decoded['channelName'] ??
                          decoded['roomId'] ??
                          '')
                      .toString();
              if (fromId != null && callId.isNotEmpty && channelId.isNotEmpty) {
                if (!_isForeground()) {
                  final String peerName = displayNameForPeer(
                    fromId,
                    fallback: fromId.toString(),
                  );
                  try {
                    _showIncomingCallNotification(
                      peerId: fromId,
                      peerName: peerName,
                      callId: callId,
                      channelId: channelId,
                    );
                  } catch (_) {}
                }
              }
            } else if (type == 'new_message') {
              final int? fromId = int.tryParse(
                (decoded['fromId'] ?? '').toString(),
              );
              final String content = (decoded['content'] ?? '').toString();
              final String timestamp = (decoded['timestamp'] ?? '').toString();
              if (fromId != null) {
                if (_userId != null && fromId != _userId) {
                  unawaited(_playWindowsSystemMessageBeep());
                  unawaited(_flashWindowsTaskbar());
                }
                if (timestamp.isNotEmpty) _lastTimeByPeer[fromId] = timestamp;
                if (content.isNotEmpty) _lastMessageByPeer[fromId] = content;
                final String nickname = (decoded['fromNickname'] ?? '')
                    .toString()
                    .trim();
                final String avatar = (decoded['fromAvatar'] ?? '')
                    .toString()
                    .trim();
                if (nickname.isNotEmpty) _nicknameByPeer[fromId] = nickname;
                if (avatar.isNotEmpty) _avatarByPeer[fromId] = avatar;
                if (_activePeerId == null || _activePeerId != fromId) {
                  _unreadByPeer[fromId] = (_unreadByPeer[fromId] ?? 0) + 1;
                }
                _syncUnreadBadge();
                if (_isForeground() &&
                    (_activePeerId == null || _activePeerId != fromId)) {
                  try {
                    if (!kIsWeb) {
                      FlutterRingtonePlayer().playNotification(volume: 1.0);
                      HapticFeedback.mediumImpact();
                    }
                  } catch (_) {}
                }
                if (!_isForeground() &&
                    (_activePeerId == null || _activePeerId != fromId)) {
                  final String title = displayNameForPeer(
                    fromId,
                    fallback: fromId.toString(),
                  );
                  final String body = _normalizePreviewText(content);
                  try {
                    _showMessageNotification(
                      peerId: fromId,
                      title: title,
                      body: body,
                    );
                  } catch (_) {}
                }
              }
            } else if (type == 'profile_update') {
              final int? userId = int.tryParse(
                (decoded['userId'] ?? '').toString(),
              );
              if (userId != null) {
                final String nickname = (decoded['nickname'] ?? '')
                    .toString()
                    .trim();
                final String avatar = (decoded['avatar'] ?? '')
                    .toString()
                    .trim();
                if (nickname.isNotEmpty) {
                  _nicknameByPeer[userId] = nickname;
                } else {
                  _nicknameByPeer.remove(userId);
                }
                if (avatar.isNotEmpty) {
                  _avatarByPeer[userId] = avatar;
                } else {
                  _avatarByPeer.remove(userId);
                }
              }
            } else if (type == 'friend_request' || type == 'friend_accepted') {
              final int? fromId = int.tryParse(
                (decoded['fromId'] ?? decoded['userId'] ?? '').toString(),
              );
              if (fromId != null) {
                final String nickname =
                    (decoded['fromNickname'] ?? decoded['nickname'] ?? '')
                        .toString()
                        .trim();
                final String avatar =
                    (decoded['fromAvatar'] ?? decoded['avatar'] ?? '')
                        .toString()
                        .trim();
                if (nickname.isNotEmpty) _nicknameByPeer[fromId] = nickname;
                if (avatar.isNotEmpty) _avatarByPeer[fromId] = avatar;
              }
            }

            if (type == 'hangup' || type == 'reject') {
              final String callId =
                  (decoded['callId'] ??
                          decoded['call_id'] ??
                          decoded['id'] ??
                          '')
                      .toString();
              final Map<String, dynamic>? overlay = callOverlay.value;
              final String overlayCallId = (overlay?['callId'] ?? '')
                  .toString();
              if (callId.isNotEmpty &&
                  overlayCallId.isNotEmpty &&
                  callId == overlayCallId) {
                clearCallOverlay();
                CallService.instance.setMinimized(false);
                CallService.instance.leaveChannel();
              }
            }
            _eventsController.add(SignalEvent(type, decoded));
          } catch (_) {}
        },
        onDone: () {
          _handleDisconnected();
        },
        onError: (_) {
          _handleDisconnected();
        },
        cancelOnError: true,
      );
    } finally {
      _connecting = false;
    }
  }

  void _handleDisconnected() {
    _channel = null;
    _sub?.cancel();
    _sub = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      connect();
    });
  }

  Future<void> disconnect() async {
    final WebSocketChannel? channel = _channel;
    _channel = null;
    await _sub?.cancel();
    _sub = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    try {
      await channel?.sink.close(ws_status.goingAway);
    } catch (_) {}
    _userId = null;
    _token = null;
    _activePeerId = null;
    _unreadByPeer.clear();
    _lastMessageByPeer.clear();
    _lastTimeByPeer.clear();
    _nicknameByPeer.clear();
    _avatarByPeer.clear();
    _remarkByPeer.clear();
    _remarksLoadedKey = '';
    _remarksLoading = false;
    _friendRequestCount = 0;
    _syncUnreadBadge();
    _syncFriendRequestBadge();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
    if (state == AppLifecycleState.resumed) {
      connect();
      Future.microtask(_consumePendingNotificationPayload);
    }
  }

  Map<String, String> _createCall(int fromId, int toId) {
    final int a = fromId < toId ? fromId : toId;
    final int b = fromId < toId ? toId : fromId;
    final String channelId = '${a}_$b';
    final String callId =
        'call_${DateTime.now().millisecondsSinceEpoch}_${fromId}_$toId';
    return {'callId': callId, 'channelId': channelId};
  }

  Map<String, String> sendCall(int fromId, int toId) {
    final WebSocketChannel? channel = _channel;
    if (channel == null) {
      throw Exception('信令未连接');
    }
    final info = _createCall(fromId, toId);
    channel.sink.add(
      jsonEncode({
        'type': 'call',
        'fromId': fromId,
        'toId': toId,
        'channelId': info['channelId'],
        'callId': info['callId'],
      }),
    );
    return info;
  }

  void sendAccept(String callId, {int? toId}) {
    final Map<String, dynamic> payload = {'type': 'accept', 'callId': callId};
    if (toId != null) payload['toId'] = toId;
    _channel?.sink.add(jsonEncode(payload));
  }

  void sendReject(String callId, {int? toId}) {
    final Map<String, dynamic> payload = {'type': 'reject', 'callId': callId};
    if (toId != null) payload['toId'] = toId;
    _channel?.sink.add(jsonEncode(payload));
  }

  void sendHangup(String callId, {int? toId}) {
    final Map<String, dynamic> payload = {'type': 'hangup', 'callId': callId};
    if (toId != null) payload['toId'] = toId;
    _channel?.sink.add(jsonEncode(payload));
  }

  Future<Map<String, dynamic>> fetchAgoraTokenSimple({
    required String channelName,
    required int uid,
    int? expireSeconds,
  }) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    if (token == null || token.trim().isEmpty) {
      throw Exception('未登录');
    }
    final Uri url = Uri.parse('$_baseUrl/api/agora/token-simple').replace(
      queryParameters: {
        'channelName': channelName,
        'uid': uid.toString(),
        if (expireSeconds != null && expireSeconds > 0)
          'expire': expireSeconds.toString(),
      },
    );
    final http.Response res = await http.get(
      url,
      headers: {'Authorization': 'Bearer $token'},
    );
    Map<String, dynamic> json = <String, dynamic>{};
    try {
      final dynamic decoded = jsonDecode(res.body);
      json = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {}
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final String msg = (json['message'] ?? '').toString().trim();
      throw Exception(msg.isNotEmpty ? msg : '获取 Token 失败(${res.statusCode})');
    }
    final dynamic tokenValue =
        json['token'] ??
        (json['data'] is Map ? (json['data'] as Map)['token'] : null);
    final String tokenStr = tokenValue is String
        ? tokenValue
        : tokenValue?.toString() ?? '';
    if (tokenStr.trim().isEmpty) {
      throw Exception('Token 数据异常');
    }
    final String appId =
        (json['appId'] ??
                (json['data'] is Map ? (json['data'] as Map)['appId'] : null) ??
                '')
            .toString()
            .trim();
    final dynamic expireAt =
        json['expireAt'] ??
        (json['data'] is Map ? (json['data'] as Map)['expireAt'] : null);
    return <String, dynamic>{
      'token': tokenStr.trim(),
      if (appId.isNotEmpty) 'appId': appId,
      if (expireAt != null) 'expireAt': expireAt,
    };
  }
}
