import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../services/call_state.dart';
import '../services/signal_service.dart';

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  bool _loading = true;
  String? _token;
  int? _userId;
  List<Map<String, dynamic>> _friends = [];
  StreamSubscription? _signalSub;
  Timer? _pollTimer;
  String _conversationsSignature = '';
  final Map<int, String> _avatarCacheKeyByUserId = <int, String>{};
  final Map<int, Uint8List> _avatarBytesCacheByUserId = <int, Uint8List>{};

  int _parseTimeMillis(String raw) {
    final String s = raw.trim();
    if (s.isEmpty) return 0;
    final int? num = int.tryParse(s);
    if (num != null) {
      if (num > 1000000000000) return num;
      if (num > 1000000000) return num * 1000;
      return num;
    }
    DateTime? dt = DateTime.tryParse(s);
    dt ??= DateTime.tryParse(s.replaceFirst(' ', 'T'));
    return dt?.millisecondsSinceEpoch ?? 0;
  }

  int _effectiveUnreadForFriend(Map<String, dynamic> friend) {
    final int? id = int.tryParse((friend['id'] ?? '').toString());
    final int mapUnread =
        int.tryParse((friend['unreadCount'] ?? 0).toString()) ?? 0;
    if (id == null) return mapUnread < 0 ? 0 : mapUnread;
    final int liveUnread = SignalService.instance.unreadForPeer(id);
    return max(mapUnread, liveUnread);
  }

  int _timeMillisForFriend(Map<String, dynamic> friend) {
    final int? peerId = int.tryParse((friend['id'] ?? '').toString());
    String raw = '';
    if (peerId != null) {
      raw = SignalService.instance.lastTimeForPeer(peerId);
    }
    if (raw.trim().isEmpty) {
      raw =
          (friend['time'] ??
                  friend['lastTime'] ??
                  friend['last_time'] ??
                  friend['timestamp'] ??
                  '')
              .toString();
    }
    return _parseTimeMillis(raw);
  }

  void _sortFriendsInPlace(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final int ua = _effectiveUnreadForFriend(a);
      final int ub = _effectiveUnreadForFriend(b);
      final bool ha = ua > 0;
      final bool hb = ub > 0;
      if (ha != hb) return hb ? 1 : -1;
      if (ha && hb && ua != ub) return ub.compareTo(ua);

      final int ta = _timeMillisForFriend(a);
      final int tb = _timeMillisForFriend(b);
      if (ta != tb) return tb.compareTo(ta);

      final int ida = int.tryParse((a['id'] ?? '').toString()) ?? 0;
      final int idb = int.tryParse((b['id'] ?? '').toString()) ?? 0;
      return idb.compareTo(ida);
    });
  }

  @override
  void initState() {
    super.initState();
    CallState.isInCall.addListener(_handleCallStateChanged);
    _signalSub = SignalService.instance.listen().listen((event) {
      if (!mounted) return;
      if (event.type == 'new_message') {
        final int? fromId = int.tryParse(
          (event.data['fromId'] ?? '').toString(),
        );
        final String content = (event.data['content'] ?? '').toString();
        final String ts = (event.data['timestamp'] ?? '').toString();
        if (fromId != null) {
          final int index = _friends.indexWhere((e) {
            final int? id = int.tryParse((e['id'] ?? '').toString());
            return id == fromId;
          });
          if (index >= 0) {
            if (content.isNotEmpty) _friends[index]['lastMessage'] = content;
            if (ts.isNotEmpty) _friends[index]['lastTime'] = ts;
            final String nickname = (event.data['fromNickname'] ?? '')
                .toString()
                .trim();
            final String avatar = (event.data['fromAvatar'] ?? '')
                .toString()
                .trim();
            final String username = (event.data['fromUsername'] ?? '')
                .toString()
                .trim();
            if (username.isNotEmpty) _friends[index]['username'] = username;
            if (nickname.isNotEmpty) _friends[index]['nickname'] = nickname;
            if (avatar.isNotEmpty) _friends[index]['avatar'] = avatar;
            _friends[index]['unreadCount'] = _effectiveUnreadForFriend(
              _friends[index],
            );
            _sortFriendsInPlace(_friends);
          } else {
            final String nickname = (event.data['fromNickname'] ?? '')
                .toString();
            final String avatar = (event.data['fromAvatar'] ?? '').toString();
            final String username = (event.data['fromUsername'] ?? '')
                .toString();
            _friends.insert(0, {
              'id': fromId,
              'username': username.isNotEmpty ? username : fromId.toString(),
              'nickname': nickname,
              'avatar': avatar,
              'lastMessage': content,
              'lastTime': ts,
              'unreadCount': SignalService.instance.unreadForPeer(fromId),
            });
            _sortFriendsInPlace(_friends);
          }
        }
        setState(() {});
      } else if (event.type == 'profile_update') {
        final int? uid = int.tryParse((event.data['userId'] ?? '').toString());
        if (uid != null) {
          final int index = _friends.indexWhere((e) {
            final int? id = int.tryParse((e['id'] ?? '').toString());
            return id == uid;
          });
          if (index >= 0) {
            final String nickname = (event.data['nickname'] ?? '')
                .toString()
                .trim();
            final String avatar = (event.data['avatar'] ?? '')
                .toString()
                .trim();
            if (nickname.isNotEmpty) {
              _friends[index]['nickname'] = nickname;
            } else {
              _friends[index].remove('nickname');
            }
            if (avatar.isNotEmpty) {
              _friends[index]['avatar'] = avatar;
            } else {
              _friends[index].remove('avatar');
            }
            setState(() {});
          }
        }
      }
    });
    _load();
    _startConversationPolling();
  }

  void _startConversationPolling() {
    if (_pollTimer != null) return;
    if (CallState.isInCall.value) return;
    if ((_token ?? '').isEmpty || _userId == null) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _fetchConversations();
    });
  }

  void _stopConversationPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _handleCallStateChanged() {
    if (CallState.isInCall.value) {
      _stopConversationPolling();
      return;
    }
    _startConversationPolling();
  }

  @override
  void dispose() {
    CallState.isInCall.removeListener(_handleCallStateChanged);
    _signalSub?.cancel();
    _stopConversationPolling();
    super.dispose();
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_token ?? ''}',
    };
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final int? userId = (int.tryParse((prefs.get('userId') ?? '').toString()));

    _token = token;
    _userId = userId;

    if (token == null || token.isEmpty || userId == null) {
      Future.microtask(() {
        Get.offAllNamed('/login');
      });
      return;
    }

    try {
      await SignalService.instance.connect();
      await _fetchConversations();
      _startConversationPolling();
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _fetchConversations() async {
    final int? userId = _userId;
    if (userId == null) return;

    final Uri url = Uri.parse(
      '$_baseUrl/api/conversations',
    ).replace(queryParameters: {'userId': userId.toString()});
    final http.Response res = await http.get(url, headers: _headers());
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '获取会话列表失败');
      return;
    }

    final dynamic decoded = jsonDecode(res.body);
    final List<dynamic> list = decoded is Map<String, dynamic>
        ? (decoded['conversations'] as List<dynamic>? ??
              decoded['friends'] as List<dynamic>? ??
              decoded['data'] as List<dynamic>? ??
              [])
        : [];

    final List<Map<String, dynamic>> next = list.whereType<Map>().map((e) {
      final m = Map<String, dynamic>.from(e);
      final int? peerId = int.tryParse((m['id'] ?? '').toString());
      if (peerId != null) {
        final int serverUnread =
            int.tryParse((m['unreadCount'] ?? 0).toString()) ?? 0;
        final int localUnread = SignalService.instance.unreadForPeer(peerId);
        final int mergedUnread = max(serverUnread, localUnread);

        final String liveNick = SignalService.instance
            .nicknameForPeer(peerId)
            .trim();
        final String liveAvatar = SignalService.instance
            .avatarForPeer(peerId)
            .trim();
        if (liveNick.isNotEmpty) m['nickname'] = liveNick;
        if (liveAvatar.isNotEmpty) m['avatar'] = liveAvatar;
        m['unreadCount'] = mergedUnread;

        final String lastMessage = (m['lastMessage'] ?? '').toString();
        final String lastTime = (m['lastTime'] ?? '').toString();
        SignalService.instance.updateConversationSnapshot(
          peerId: peerId,
          lastMessage: lastMessage.isEmpty ? null : lastMessage,
          lastTime: lastTime.isEmpty ? null : lastTime,
          unreadCount: mergedUnread,
        );
      }
      return m;
    }).toList();

    _sortFriendsInPlace(next);

    final String nextSignature = next
        .map((m) {
          final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
          final int unread =
              int.tryParse((m['unreadCount'] ?? 0).toString()) ?? 0;
          final String lastTime = (m['lastTime'] ?? '').toString();
          final String lastMessage = (m['lastMessage'] ?? '').toString();
          final String nickname = (m['nickname'] ?? '').toString();
          final String avatar = (m['avatar'] ?? '').toString();
          final int avatarKey = avatar.isEmpty
              ? 0
              : Object.hash(avatar.length, avatar.hashCode);
          return '$id|$unread|$lastTime|$lastMessage|$nickname|$avatarKey';
        })
        .join('||');

    if (!mounted) return;
    if (nextSignature == _conversationsSignature) return;
    setState(() {
      _friends = next;
      _conversationsSignature = nextSignature;
    });
  }

  String _previewText(Map<String, dynamic> friend) {
    final int? peerId = int.tryParse((friend['id'] ?? '').toString());
    if (peerId != null) {
      final String live = SignalService.instance.lastMessageForPeer(peerId);
      if (live.isNotEmpty) return _normalizePreviewText(live);
    }
    final dynamic v =
        friend['lastMessage'] ??
        friend['last_message'] ??
        friend['preview'] ??
        friend['last_message_preview'];
    return _normalizePreviewText((v ?? '').toString());
  }

  String _displayName(Map<String, dynamic> user) {
    final int? id = int.tryParse((user['id'] ?? '').toString());
    final String nickname = (user['nickname'] ?? user['displayName'] ?? '')
        .toString()
        .trim();
    final String username = (user['username'] ?? user['name'] ?? '')
        .toString()
        .trim();
    if (id != null) {
      final String fallback = nickname.isNotEmpty
          ? nickname
          : (username.isNotEmpty ? username : '');
      final String live = SignalService.instance.displayNameForPeer(
        id,
        fallback: fallback,
      );
      if (live.isNotEmpty) return live;
    }
    if (nickname.isNotEmpty) return nickname;
    if (username.isNotEmpty) return username;
    final String rawId = (user['id'] ?? '').toString().trim();
    return rawId.isNotEmpty ? 'ID:$rawId' : '未知用户';
  }

  Uint8List? _avatarBytes(Map<String, dynamic> user) {
    final int? id = int.tryParse((user['id'] ?? '').toString());
    final int cacheId = id ?? -1;
    if (id != null) {
      final String live = SignalService.instance.avatarForPeer(id);
      if (live.isNotEmpty) {
        return _decodeAvatarData(live, cacheId: cacheId);
      }
    }
    final String avatar = (user['avatar'] ?? user['avatarData'] ?? '')
        .toString()
        .trim();
    return _decodeAvatarData(avatar, cacheId: cacheId);
  }

  Uint8List? _decodeAvatarData(String avatar, {required int cacheId}) {
    final String a = avatar.trim();
    if (!a.startsWith('data:image/')) return null;
    final int idx = a.indexOf(';base64,');
    if (idx < 0) return null;
    final String b64 = a.substring(idx + ';base64,'.length);
    final String key = '${a.length}_${a.hashCode}';
    final String? lastKey = _avatarCacheKeyByUserId[cacheId];
    final Uint8List? cached = _avatarBytesCacheByUserId[cacheId];
    if (lastKey == key && cached != null) return cached;
    try {
      final Uint8List bytes = base64Decode(b64);
      _avatarCacheKeyByUserId[cacheId] = key;
      _avatarBytesCacheByUserId[cacheId] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Widget _avatarWidget(Map<String, dynamic> user, String fallbackText) {
    final Uint8List? bytes = _avatarBytes(user);
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return Text(
      fallbackText,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    );
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

  String _timeText(Map<String, dynamic> friend) {
    final int? peerId = int.tryParse((friend['id'] ?? '').toString());
    if (peerId != null) {
      final String live = SignalService.instance.lastTimeForPeer(peerId);
      if (live.isNotEmpty) {
        if (live.length >= 16) return live.substring(11, min(16, live.length));
        return live;
      }
    }
    final dynamic v =
        friend['time'] ??
        friend['lastTime'] ??
        friend['last_time'] ??
        friend['timestamp'];
    final String raw = (v ?? '').toString().trim();
    if (raw.isEmpty) return '';
    if (raw.length >= 16) return raw.substring(11, min(16, raw.length));
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('消息')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _friends.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 44,
                    color: Color(0xFF555555),
                  ),
                  SizedBox(height: 10),
                  Text(
                    '暂无消息，添加好友开始聊天',
                    style: TextStyle(color: Color(0xFF8B8B8B)),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _fetchConversations,
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
                itemCount: _friends.length,
                itemBuilder: (context, index) {
                  final Map<String, dynamic> f = _friends[index];
                  final int? id = int.tryParse((f['id'] ?? '').toString());
                  final String preview = _previewText(f);
                  final String time = _timeText(f);
                  final String displayName = _displayName(f);
                  final String avatarText = displayName.characters.first
                      .toUpperCase();
                  final int unread = id == null
                      ? 0
                      : SignalService.instance.unreadForPeer(id);

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 5,
                    ),
                    child: Material(
                      color: const Color(0xFF0F131E),
                      borderRadius: const BorderRadius.all(Radius.circular(14)),
                      child: InkWell(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(14),
                        ),
                        onTap: id == null
                            ? null
                            : () {
                                SignalService.instance.clearUnreadForPeer(id);
                                final int idx = _friends.indexWhere((e) {
                                  final int? peerId = int.tryParse(
                                    (e['id'] ?? '').toString(),
                                  );
                                  return peerId == id;
                                });
                                if (idx >= 0) {
                                  _friends[idx]['unreadCount'] = 0;
                                }
                                _sortFriendsInPlace(_friends);
                                setState(() {});
                                try {
                                  final int? myId = _userId;
                                  if (myId != null) {
                                    http.post(
                                      Uri.parse('$_baseUrl/api/messages/read'),
                                      headers: _headers(),
                                      body: jsonEncode({
                                        'userId': myId,
                                        'peerId': id,
                                      }),
                                    );
                                  }
                                } catch (_) {}
                                Get.toNamed(
                                  '/chat',
                                  parameters: {
                                    'peerId': id.toString(),
                                    'peerUsername': displayName,
                                  },
                                )?.then((_) {
                                  _fetchConversations();
                                });
                              },
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(0xFF1A1F2E),
                                ),
                                alignment: Alignment.center,
                                child: _avatarWidget(f, avatarText),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      displayName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFFE8E8E8),
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      preview.isEmpty ? ' ' : preview,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Color(0xFF8B8B8B),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    time,
                                    style: const TextStyle(
                                      color: Color(0xFF555555),
                                      fontSize: 11,
                                    ),
                                  ),
                                  const SizedBox(height: 18),
                                  if (unread > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      height: 18,
                                      constraints: const BoxConstraints(
                                        minWidth: 18,
                                      ),
                                      decoration: const BoxDecoration(
                                        color: Color(0xFFC62828),
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(10),
                                        ),
                                      ),
                                      alignment: Alignment.center,
                                      child: Text(
                                        unread > 99 ? '99+' : unread.toString(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          height: 1.0,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
