import 'dart:async';
import 'dart:convert';

import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'call_state.dart';

class CallService {
  static const String agoraAppId = 'cae989abb9554b03bc39e59665c009f2';
  static const String _baseUrl = 'https://fenghuomixin.online';

  static final CallService instance = CallService._();

  CallService._();

  RtcEngine? _engine;
  bool _speakerphoneEnabled = false;
  bool _muted = false;
  bool _minimized = false;
  String? _runtimeAgoraAppId;
  Future<RtcEngine>? _joinFuture;

  String _effectiveAgoraAppId() {
    final String v = (_runtimeAgoraAppId ?? '').trim();
    return v.isNotEmpty ? v : agoraAppId;
  }

  Future<void> _disposeEngine(RtcEngine? engine) async {
    if (engine == null) return;
    try {
      await engine.leaveChannel();
    } catch (_) {}
    try {
      await engine.release();
    } catch (_) {}
  }

  Future<Map<String, String>> _fetchRtcToken({
    required String channelName,
    required int uid,
    required String authToken,
  }) async {
    final List<Uri> candidates = [
      Uri.parse('$_baseUrl/api/agora/token-simple').replace(
        queryParameters: {'channelName': channelName, 'uid': uid.toString()},
      ),
      Uri.parse('$_baseUrl/api/agora/token').replace(
        queryParameters: {'channel': channelName, 'uid': uid.toString()},
      ),
      Uri.parse('$_baseUrl/api/agora/token').replace(
        queryParameters: {'channelName': channelName, 'uid': uid.toString()},
      ),
    ];

    String lastError = '获取 Token 失败';
    for (final url in candidates) {
      try {
        final http.Response tokenRes = await http.get(
          url,
          headers: {'Authorization': 'Bearer $authToken'},
        );
        Map<String, dynamic> json = <String, dynamic>{};
        try {
          final dynamic decoded = jsonDecode(tokenRes.body);
          json = decoded is Map<String, dynamic>
              ? decoded
              : <String, dynamic>{};
        } catch (_) {}

        if (tokenRes.statusCode < 200 || tokenRes.statusCode >= 300) {
          final String msg = (json['message'] ?? '').toString().trim();
          lastError = msg.isNotEmpty
              ? msg
              : '获取 Token 失败(${tokenRes.statusCode})';
          continue;
        }

        final dynamic token =
            json['token'] ??
            (json['data'] is Map ? (json['data'] as Map)['token'] : null);
        final String tokenStr = token is String
            ? token
            : token?.toString() ?? '';
        if (tokenStr.trim().isEmpty) {
          lastError = 'Token 数据异常';
          continue;
        }

        final String appId =
            (json['appId'] ??
                    (json['data'] is Map
                        ? (json['data'] as Map)['appId']
                        : null) ??
                    '')
                .toString()
                .trim();
        return <String, String>{'token': tokenStr.trim(), 'appId': appId};
      } catch (e) {
        lastError = e.toString().replaceFirst('Exception: ', '');
      }
    }
    throw Exception(lastError);
  }

  Future<RtcEngine> joinChannel({
    required String channelName,
    void Function()? onJoined,
    void Function()? onLeft,
  }) async {
    if (kIsWeb) {
      throw Exception('Web 端暂不支持语音通话，请在手机端使用');
    }
    final Future<RtcEngine>? existingJoin = _joinFuture;
    if (existingJoin != null) {
      return existingJoin;
    }
    final RtcEngine? existingEngine = _engine;
    if (existingEngine != null) {
      return existingEngine;
    }

    final Completer<RtcEngine> joinCompleter = Completer<RtcEngine>();
    _joinFuture = joinCompleter.future;

    RtcEngine? createdEngine;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? authToken = prefs.getString('token');
      if (authToken == null || authToken.isEmpty) {
        throw Exception('未登录');
      }

      final int uid =
          (int.tryParse((prefs.get('userId') ?? '').toString())) ?? 0;

      final Map<String, String> tokenRes = await _fetchRtcToken(
        channelName: channelName,
        uid: uid,
        authToken: authToken,
      );
      final String token = (tokenRes['token'] ?? '').trim();
      final String appId = (tokenRes['appId'] ?? '').trim();
      if (appId.isNotEmpty) _runtimeAgoraAppId = appId;

      await _disposeEngine(_engine);
      _engine = null;

      final RtcEngine engine = createAgoraRtcEngine();
      createdEngine = engine;
      _engine = engine;
      await engine.initialize(RtcEngineContext(appId: _effectiveAgoraAppId()));
      await engine.enableAudio();
      try {
        await engine.setEnableSpeakerphone(_speakerphoneEnabled);
      } catch (_) {}
      try {
        await engine.muteLocalAudioStream(_muted);
      } catch (_) {}

      final Completer<void> joined = Completer<void>();
      final Completer<String> failed = Completer<String>();

      engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (connection, elapsed) {
            if (!joined.isCompleted) joined.complete();
            onJoined?.call();
          },
          onError: (err, msg) {
            final String text = msg.trim().isEmpty
                ? 'Agora 错误码: $err'
                : 'Agora 错误码: $err，${msg.trim()}';
            if (!failed.isCompleted) failed.complete(text);
          },
          onConnectionStateChanged: (connection, state, reason) {
            if (state == ConnectionStateType.connectionStateFailed) {
              if (!failed.isCompleted) failed.complete('连接失败($reason)');
            }
          },
          onLeaveChannel: (connection, stats) {
            onLeft?.call();
          },
        ),
      );

      await engine.joinChannel(
        token: token,
        channelId: channelName,
        uid: uid,
        options: const ChannelMediaOptions(
          channelProfile: ChannelProfileType.channelProfileCommunication,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );

      final dynamic r = await Future.any<dynamic>([
        joined.future,
        failed.future,
        Future<void>.delayed(const Duration(seconds: 12)),
      ]);

      if (r is String && r.trim().isNotEmpty) {
        throw Exception(r.trim());
      }
      if (!joined.isCompleted) {
        throw Exception('加入语音频道超时');
      }

      CallState.setInCall(true);
      if (!joinCompleter.isCompleted) {
        joinCompleter.complete(engine);
      }
      return engine;
    } catch (e, st) {
      if (identical(_engine, createdEngine)) {
        _engine = null;
      }
      await _disposeEngine(createdEngine);
      CallState.setInCall(false);
      if (!joinCompleter.isCompleted) {
        joinCompleter.completeError(e, st);
      }
      rethrow;
    } finally {
      _joinFuture = null;
    }
  }

  Future<void> leaveChannel() async {
    final engine = _engine;
    _engine = null;
    _minimized = false;
    _joinFuture = null;
    CallState.setInCall(false);
    if (engine == null) return;
    await _disposeEngine(engine);
  }

  Future<void> mute(bool muted) async {
    _muted = muted;
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.muteLocalAudioStream(muted);
    } catch (_) {}
  }

  bool speakerphoneEnabled() => _speakerphoneEnabled;

  Future<void> setSpeakerphoneEnabled(bool enabled) async {
    _speakerphoneEnabled = enabled;
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.setEnableSpeakerphone(enabled);
    } catch (_) {}
  }

  Future<void> toggleSpeakerphone() async {
    await setSpeakerphoneEnabled(!_speakerphoneEnabled);
  }

  void setMinimized(bool minimized) {
    _minimized = minimized;
  }

  bool isMinimized() => _minimized;

  bool isInCall() => _engine != null;
}
