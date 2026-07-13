import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../services/call_state.dart';
import '../services/signal_service.dart';
import 'search_user_page.dart';

class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage>
    with WidgetsBindingObserver {
  static const String _baseUrl = 'https://fenghuomixin.online';

  bool _loading = true;
  String? _token;
  int? _userId;

  List<Map<String, dynamic>> _friends = [];
  List<Map<String, dynamic>> _requests = [];
  StreamSubscription? _signalSub;
  Timer? _pollTimer;
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    CallState.isInCall.addListener(_handleCallStateChanged);
    _signalSub = SignalService.instance.listen().listen((event) {
      if (!mounted) return;
      if (event.type == 'friend_request') {
        _fetchRequests();
      } else if (event.type == 'friend_accepted') {
        _fetchFriends();
        _fetchRequests();
      } else if (event.type == 'profile_update') {
        _fetchFriends();
        _fetchRequests();
      }
    });
    _load();
    _startRequestPolling();
  }

  void _startRequestPolling() {
    if (_pollTimer != null) return;
    if (CallState.isInCall.value) return;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      if (_token == null || (_token?.isEmpty ?? true) || _userId == null) {
        return;
      }
      if (_loading) return;
      _fetchRequests();
    });
  }

  void _stopRequestPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _handleCallStateChanged() {
    if (CallState.isInCall.value) {
      _stopRequestPolling();
      return;
    }
    _startRequestPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    CallState.isInCall.removeListener(_handleCallStateChanged);
    _signalSub?.cancel();
    _stopRequestPolling();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetchRequests();
      _fetchFriends();
    }
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
      await Future.wait([_fetchFriends(), _fetchRequests()]);
      _startRequestPolling();
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_token ?? ''}',
    };
  }

  String _displayName(Map<String, dynamic> u) {
    final int? id = int.tryParse(
      (u['id'] ?? u['from_user_id'] ?? u['user_id'] ?? '').toString(),
    );
    final String nickname = (u['nickname'] ?? u['from_nickname'] ?? '')
        .toString()
        .trim();
    final String username =
        (u['username'] ?? u['from_username'] ?? u['name'] ?? '')
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
    final String rawId = (u['id'] ?? u['from_user_id'] ?? u['user_id'] ?? '')
        .toString()
        .trim();
    return rawId.isNotEmpty ? 'ID:$rawId' : '未知用户';
  }

  Uint8List? _avatarBytes(Map<String, dynamic> u) {
    final String avatar = (u['avatar'] ?? u['from_avatar'] ?? '')
        .toString()
        .trim();
    if (!avatar.startsWith('data:image/')) return null;
    final int idx = avatar.indexOf(';base64,');
    if (idx < 0) return null;
    final String b64 = avatar.substring(idx + ';base64,'.length);
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Widget _avatarWidget(Map<String, dynamic> u, String fallbackText) {
    final Uint8List? bytes = _avatarBytes(u);
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(bytes, width: 44, height: 44, fit: BoxFit.cover),
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

  Future<void> _fetchFriends() async {
    final int? userId = _userId;
    if (userId == null) return;

    final Uri url = Uri.parse('$_baseUrl/api/friend/list/$userId');
    final http.Response res = await http.get(url, headers: _headers());
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '获取好友列表失败');
      return;
    }

    final dynamic decoded = jsonDecode(res.body);
    final List<dynamic> list = decoded is Map<String, dynamic>
        ? (decoded['friends'] as List<dynamic>? ??
              decoded['data'] as List<dynamic>? ??
              [])
        : [];

    setState(() {
      _friends = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    });
  }

  Future<void> _fetchRequests() async {
    final int? userId = _userId;
    if (userId == null) return;

    final Uri url = Uri.parse('$_baseUrl/api/friend/requests/$userId');
    final http.Response res = await http.get(url, headers: _headers());
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }

    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '获取好友申请失败');
      return;
    }

    final dynamic decoded = jsonDecode(res.body);
    final List<dynamic> list = decoded is Map<String, dynamic>
        ? (decoded['requests'] as List<dynamic>? ??
              decoded['data'] as List<dynamic>? ??
              [])
        : [];

    setState(() {
      _requests = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    });
    SignalService.instance.setFriendRequestCount(_requests.length);
  }

  Future<void> _acceptRequest(int requesterId) async {
    final int? userId = _userId;
    if (userId == null) return;

    final Uri url = Uri.parse('$_baseUrl/api/friend/accept');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({'userId': userId, 'requesterId': requesterId}),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '同意失败');
      return;
    }
    await Future.wait([_fetchFriends(), _fetchRequests()]);
  }

  Future<void> _rejectRequest(int requesterId) async {
    final int? userId = _userId;
    if (userId == null) return;

    final Uri url = Uri.parse('$_baseUrl/api/friend/reject');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({'userId': userId, 'requesterId': requesterId}),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '拒绝失败');
      return;
    }
    await _fetchRequests();
  }

  void _openScanPage() {
    Get.to(
      () => Scaffold(
        appBar: AppBar(title: const Text('扫码')),
        body: const Center(child: Text('扫码')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('通讯录'),
          backgroundColor: const Color(0xFF0F131E),
          actions: [
            IconButton(
              icon: const Icon(Icons.search),
              color: const Color(0xFFB8960C),
              onPressed: () async {
                await Get.to(() => const SearchUserPage());
                if (mounted) {
                  _load();
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.qr_code_scanner_outlined),
              color: const Color(0xFFB8960C),
              onPressed: _openScanPage,
            ),
          ],
          bottom: TabBar(
            indicatorColor: Color(0xFFB8960C),
            labelColor: Color(0xFFE8E8E8),
            unselectedLabelColor: Color(0xFF8B8B8B),
            onTap: (i) {
              _activeTabIndex = i;
            },
            tabs: [
              const Tab(text: '我的好友'),
              Tab(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Align(
                      alignment: Alignment.center,
                      child: Text('好友申请'),
                    ),
                    if (_requests.isNotEmpty)
                      Positioned(
                        right: -18,
                        top: -4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5),
                          height: 16,
                          constraints: const BoxConstraints(minWidth: 16),
                          decoration: const BoxDecoration(
                            color: Color(0xFFC62828),
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            _requests.length > 99
                                ? '99+'
                                : _requests.length.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: InkWell(
                      borderRadius: const BorderRadius.all(Radius.circular(24)),
                      onTap: () async {
                        await Get.to(() => const SearchUserPage());
                        if (mounted) {
                          _load();
                        }
                      },
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        decoration: const BoxDecoration(
                          color: Color(0xFF141825),
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.search, color: Color(0xFFB8960C)),
                            SizedBox(width: 10),
                            Text(
                              '搜索用户',
                              style: TextStyle(color: Color(0xFF555555)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [_buildFriends(), _buildRequests()],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildFriends() {
    if (_friends.isEmpty) {
      return const Center(
        child: Text('暂无好友', style: TextStyle(color: Color(0xFF8B8B8B))),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchFriends,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _friends.length,
        itemBuilder: (context, index) {
          final Map<String, dynamic> f = _friends[index];
          final int? id = int.tryParse((f['id'] ?? '').toString());
          final String displayName = _displayName(f);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Material(
              color: const Color(0xFF0F131E),
              borderRadius: const BorderRadius.all(Radius.circular(14)),
              child: InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(14)),
                onTap: id == null
                    ? null
                    : () {
                        Get.toNamed(
                          '/chat',
                          parameters: {
                            'peerId': id.toString(),
                            'peerUsername': displayName,
                          },
                        );
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
                        child: _avatarWidget(
                          f,
                          displayName.characters.first.toUpperCase(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFE8E8E8),
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildRequests() {
    if (_requests.isEmpty) {
      return const Center(
        child: Text('暂无好友申请', style: TextStyle(color: Color(0xFF8B8B8B))),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchRequests,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _requests.length,
        itemBuilder: (context, index) {
          final Map<String, dynamic> r = _requests[index];
          final int? requesterId = int.tryParse(
            (r['user_id'] ?? r['from_user_id'] ?? r['requesterId'] ?? '')
                .toString(),
          );
          final String displayName = _displayName(r);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            child: Material(
              color: const Color(0xFF0F131E),
              borderRadius: const BorderRadius.all(Radius.circular(14)),
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
                      child: _avatarWidget(
                        r,
                        displayName.characters.first.toUpperCase(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFE8E8E8),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (requesterId != null) ...[
                      SizedBox(
                        height: 36,
                        child: ElevatedButton(
                          onPressed: () => _acceptRequest(requesterId),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2E7D32),
                            foregroundColor: Colors.white,
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(12),
                              ),
                            ),
                          ),
                          child: const Text('同意'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 36,
                        child: OutlinedButton(
                          onPressed: () => _rejectRequest(requesterId),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFC62828),
                            side: const BorderSide(color: Colors.transparent),
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.all(
                                Radius.circular(12),
                              ),
                            ),
                          ),
                          child: const Text('拒绝'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
