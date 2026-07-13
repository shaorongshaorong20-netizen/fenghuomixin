import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/call_service.dart';
import '../services/signal_service.dart';

enum _CallUiState { outgoing, incoming, inCall, ended }

class CallPage extends StatefulWidget {
  final String peerUsername;
  final int peerId;
  final String callId;
  final String channelId;
  final String direction;
  final int? startedAtMs;

  const CallPage({
    super.key,
    required this.peerUsername,
    required this.peerId,
    required this.callId,
    required this.channelId,
    required this.direction,
    this.startedAtMs,
  });

  static Widget fromRoute() {
    String peerUsername = '';
    int? peerId;
    String callId = '';
    String channelId = '';
    String direction = '';
    int? startedAtMs;

    final params = Get.parameters;
    peerUsername = (params['peerUsername'] ?? params['username'] ?? '')
        .toString();
    peerId = int.tryParse((params['peerId'] ?? '').toString());
    callId = (params['callId'] ?? '').toString();
    channelId = (params['channelId'] ?? params['channel'] ?? '').toString();
    direction = (params['direction'] ?? '').toString();
    startedAtMs = int.tryParse((params['startedAtMs'] ?? '').toString());

    final dynamic args = Get.arguments;
    if (args is Map) {
      if (peerUsername.isEmpty) {
        peerUsername = (args['peerUsername'] ?? args['username'] ?? '')
            .toString();
      }
      peerId ??= int.tryParse((args['peerId'] ?? '').toString());
      if (callId.isEmpty) {
        callId = (args['callId'] ?? '').toString();
      }
      if (channelId.isEmpty) {
        channelId = (args['channelId'] ?? args['channel'] ?? '').toString();
      }
      if (direction.isEmpty) {
        direction = (args['direction'] ?? '').toString();
      }
      startedAtMs ??= int.tryParse((args['startedAtMs'] ?? '').toString());
    }

    if (peerId == null || callId.isEmpty || channelId.isEmpty) {
      return const _CallRouteErrorPage();
    }

    return CallPage(
      peerUsername: peerUsername.isEmpty ? '通话' : peerUsername,
      peerId: peerId,
      callId: callId,
      channelId: channelId,
      direction: direction.isEmpty ? 'outgoing' : direction,
      startedAtMs: startedAtMs,
    );
  }

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  _CallUiState _state = _CallUiState.outgoing;
  String? _errorText;
  bool _joining = false;
  String _peerDisplayName = '';
  bool _muted = false;
  bool _speakerOn = false;
  bool _ringing = false;

  Timer? _timer;
  int _seconds = 0;
  StreamSubscription? _signalSub;

  @override
  void initState() {
    super.initState();
    _peerDisplayName = widget.peerUsername;
    if (widget.direction == 'incoming') {
      _state = _CallUiState.incoming;
    } else if (widget.direction == 'inCall') {
      _state = _CallUiState.inCall;
    } else {
      _state = _CallUiState.outgoing;
    }
    if (kIsWeb) {
      _state = _CallUiState.ended;
      _errorText = '请在手机 App 中使用语音通话功能';
      return;
    }

    _updateRingtone();
    _fetchPeerProfile();
    if (_state == _CallUiState.inCall) {
      final int? startedAt = widget.startedAtMs;
      if (startedAt != null && startedAt > 0) {
        final int diff = DateTime.now().millisecondsSinceEpoch - startedAt;
        _seconds = diff > 0 ? (diff ~/ 1000) : 0;
      }
      _speakerOn = CallService.instance.speakerphoneEnabled();
      _startTimer();
    }
    _signalSub = SignalService.instance.listen().listen((event) {
      if (!mounted) return;
      final String callId =
          (event.data['callId'] ??
                  event.data['call_id'] ??
                  event.data['id'] ??
                  '')
              .toString();
      if (callId.isNotEmpty && callId != widget.callId) return;

      if (event.type == 'accept') {
        if (_state == _CallUiState.outgoing) {
          _enterInCall();
        }
      } else if (event.type == 'call_failed') {
        if (_state == _CallUiState.outgoing) {
          final String msg = (event.data['message'] ?? '').toString().trim();
          if (msg.isNotEmpty) {
            Get.snackbar('提示', msg);
          } else {
            Get.snackbar('提示', '用户不在线');
          }
          _endAndPop();
        }
      } else if (event.type == 'reject') {
        _endAndPop();
      } else if (event.type == 'hangup') {
        _endAndPop();
      }
    });
  }

  Future<void> _fetchPeerProfile() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? token = prefs.getString('token');
      if (token == null || token.isEmpty) return;
      final Uri url = Uri.parse(
        '$_baseUrl/api/user/public',
      ).replace(queryParameters: {'userId': widget.peerId.toString()});
      final http.Response res = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 401) return;
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final dynamic decoded = jsonDecode(res.body);
      final dynamic data = decoded is Map<String, dynamic>
          ? decoded['data']
          : null;
      if (data is! Map) return;
      final String nickname = (data['nickname'] ?? '').toString().trim();
      final String username = (data['username'] ?? '').toString().trim();
      final String next = nickname.isNotEmpty
          ? nickname
          : (username.isNotEmpty ? username : _peerDisplayName);
      if (!mounted) return;
      setState(() {
        _peerDisplayName = next;
      });
    } catch (_) {}
  }

  String _formatDuration(int seconds) {
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    final String mm = m.toString().padLeft(2, '0');
    final String ss = s.toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _seconds += 1;
      });
    });
  }

  Future<void> _hangUp() async {
    try {
      SignalService.instance.clearCallOverlay();
      CallService.instance.setMinimized(false);
      SignalService.instance.sendHangup(widget.callId, toId: widget.peerId);
      _stopRingtone();
      await CallService.instance.leaveChannel();
    } finally {
      if (mounted) {
        setState(() {
          _state = _CallUiState.ended;
        });
        _updateRingtone();
      }
    }
  }

  void _endAndPop() {
    _timer?.cancel();
    _stopRingtone();
    if (mounted) {
      setState(() {
        _state = _CallUiState.ended;
      });
      SignalService.instance.clearCallOverlay();
      CallService.instance.setMinimized(false);
      CallService.instance.leaveChannel();
      _updateRingtone();
    }
  }

  Future<void> _joinRtc() async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _errorText = null;
    });

    try {
      await CallService.instance.joinChannel(
        channelName: widget.channelId,
        onJoined: () {
          if (!mounted) return;
          _startTimer();
        },
        onLeft: () {},
      );
      try {
        await CallService.instance.mute(_muted);
      } catch (_) {}
      try {
        await CallService.instance.setSpeakerphoneEnabled(_speakerOn);
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      final String msg = e.toString().replaceFirst('Exception: ', '').trim();
      setState(() {
        _joining = false;
        _errorText = msg;
        _state = _CallUiState.ended;
      });
      final String toast = msg.isNotEmpty ? msg : '未知错误';
      try {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('通话失败：$toast')));
      } catch (_) {}
      try {
        Get.snackbar('通话失败', toast);
      } catch (_) {}
      try {
        SignalService.instance.sendHangup(widget.callId, toId: widget.peerId);
      } catch (_) {}
    } finally {
      _joining = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _enterInCall() {
    if (!mounted) return;
    if (_joining) return;
    if (_state == _CallUiState.inCall && CallService.instance.isInCall()) {
      return;
    }
    setState(() {
      _state = _CallUiState.inCall;
      _seconds = 0;
      _muted = false;
      _speakerOn = false;
    });
    CallService.instance.setMinimized(false);
    _stopRingtone();
    _joinRtc();
  }

  void _minimize() {
    if (_state != _CallUiState.inCall) return;
    final int startedAt =
        DateTime.now().millisecondsSinceEpoch - (_seconds * 1000);
    CallService.instance.setMinimized(true);
    SignalService.instance.showCallOverlay(
      peerId: widget.peerId,
      peerName: _peerDisplayName,
      callId: widget.callId,
      channelId: widget.channelId,
      startedAtMs: startedAt,
    );
    Get.back();
  }

  Future<void> _toggleMute() async {
    final bool next = !_muted;
    setState(() {
      _muted = next;
    });
    try {
      await CallService.instance.mute(next);
    } catch (_) {}
  }

  Future<void> _toggleSpeaker() async {
    final bool next = !_speakerOn;
    setState(() {
      _speakerOn = next;
    });
    try {
      await CallService.instance.setSpeakerphoneEnabled(next);
    } catch (_) {}
  }

  Future<void> _answer() async {
    final PermissionStatus status = await Permission.microphone.status;
    PermissionStatus granted = status;
    if (!granted.isGranted) {
      granted = await Permission.microphone.request();
    }
    if (!granted.isGranted) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('需要麦克风权限'),
            content: const Text(
              '请在系统设置中开启“麦克风”权限后再接听通话。\n路径：设置 → 隐私与安全性 → 麦克风',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await openAppSettings();
                },
                child: const Text('去设置'),
              ),
            ],
          );
        },
      );
      return;
    }
    _stopRingtone();
    SignalService.instance.sendAccept(widget.callId, toId: widget.peerId);
    _enterInCall();
  }

  Future<void> _reject() async {
    _stopRingtone();
    SignalService.instance.sendReject(widget.callId, toId: widget.peerId);
    _endAndPop();
  }

  void _updateRingtone() {
    if (kIsWeb) return;
    final bool shouldRing =
        _state == _CallUiState.outgoing || _state == _CallUiState.incoming;
    if (shouldRing) {
      _startRingtone();
    } else {
      _stopRingtone();
    }
  }

  void _startRingtone() {
    if (_ringing) return;
    _ringing = true;
    try {
      FlutterRingtonePlayer().playRingtone();
    } catch (_) {}
  }

  void _stopRingtone() {
    if (!_ringing) return;
    _ringing = false;
    try {
      FlutterRingtonePlayer().stop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    _signalSub?.cancel();
    _stopRingtone();
    if (!CallService.instance.isMinimized()) {
      CallService.instance.leaveChannel();
    }
    super.dispose();
  }

  String _statusText() {
    if (_errorText != null && _errorText!.trim().isNotEmpty) {
      return _errorText!.trim();
    }
    switch (_state) {
      case _CallUiState.outgoing:
        return '等待对方接听';
      case _CallUiState.incoming:
        return '来电中...';
      case _CallUiState.inCall:
        return _joining ? '连接中...' : _formatDuration(_seconds);
      case _CallUiState.ended:
        return '已结束';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1321),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const SizedBox(width: 44),
                  Expanded(
                    child: Text(
                      _peerDisplayName,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: _state == _CallUiState.inCall
                        ? IconButton(
                            onPressed: _minimize,
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              color: Colors.white,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _statusText(),
              style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 14),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
              child: _buildActions(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    if (_state == _CallUiState.incoming) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CircleActionButton(
            icon: Icons.call_end,
            label: '拒绝',
            onPressed: _reject,
            backgroundColor: const Color(0xFFC62828),
            iconColor: Colors.white,
          ),
          _CircleActionButton(
            icon: Icons.call,
            label: '接听',
            onPressed: _answer,
            backgroundColor: const Color(0xFF2E7D32),
            iconColor: Colors.white,
          ),
        ],
      );
    }

    if (_state == _CallUiState.outgoing || _state == _CallUiState.inCall) {
      if (_state == _CallUiState.inCall) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _CircleActionButton(
              icon: _muted ? Icons.mic_off : Icons.mic,
              label: _muted ? '取消静音' : '静音',
              onPressed: _toggleMute,
              backgroundColor: const Color(0xFF1A2236),
              iconColor: Colors.white,
            ),
            _CircleActionButton(
              icon: Icons.call_end,
              label: '挂断',
              onPressed: _hangUp,
              backgroundColor: const Color(0xFFC62828),
              iconColor: Colors.white,
            ),
            _CircleActionButton(
              icon: _speakerOn ? Icons.volume_up : Icons.hearing,
              label: _speakerOn ? '外放' : '听筒',
              onPressed: _toggleSpeaker,
              backgroundColor: const Color(0xFF1A2236),
              iconColor: Colors.white,
            ),
          ],
        );
      }
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CircleActionButton(
            icon: Icons.call_end,
            label: '挂断',
            onPressed: _hangUp,
            backgroundColor: const Color(0xFFC62828),
            iconColor: Colors.white,
          ),
        ],
      );
    }

    if (_state == _CallUiState.ended) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _CircleActionButton(
            icon: Icons.arrow_back,
            label: '返回',
            onPressed: () {
              Get.back();
            },
            backgroundColor: const Color(0xFF1A2236),
            iconColor: Colors.white,
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }
}

class _CircleActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color backgroundColor;
  final Color iconColor;

  const _CircleActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.backgroundColor,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkResponse(
          onTap: onPressed,
          radius: 36,
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: backgroundColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 30),
          ),
        ),
        const SizedBox(height: 10),
        Text(label, style: const TextStyle(color: Colors.white)),
      ],
    );
  }
}

class _CallRouteErrorPage extends StatelessWidget {
  const _CallRouteErrorPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('参数错误')));
  }
}
