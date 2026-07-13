import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SearchUserPage extends StatefulWidget {
  const SearchUserPage({super.key});

  @override
  State<SearchUserPage> createState() => _SearchUserPageState();
}

class _SearchUserPageState extends State<SearchUserPage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  final TextEditingController _controller = TextEditingController();

  bool _loading = false;
  String? _token;
  int? _userId;
  List<Map<String, dynamic>> _results = [];
  final Set<int> _sentFriendRequests = <int>{};

  @override
  void initState() {
    super.initState();
    _loadAuth();
  }

  Future<void> _loadAuth() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final int? userId = int.tryParse((prefs.get('userId') ?? '').toString());
    setState(() {
      _token = token;
      _userId = (userId != null && userId > 0) ? userId : null;
    });
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_token ?? ''}',
    };
  }

  Future<void> _search() async {
    final String keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    if (_token == null || _token!.isEmpty || _userId == null) {
      Get.offAllNamed('/login');
      return;
    }

    setState(() {
      _loading = true;
    });

    try {
      final Uri url = Uri.parse('$_baseUrl/api/user/search')
          .replace(queryParameters: {'username': keyword});
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        Get.snackbar('错误', '搜索失败');
        return;
      }

      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> list = decoded is Map<String, dynamic>
          ? (decoded['users'] as List<dynamic>? ?? decoded['data'] as List<dynamic>? ?? [])
          : [];

      setState(() {
        _results =
            list.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      });
    } catch (_) {
      Get.snackbar('错误', '搜索失败');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _addFriend(int friendId) async {
    final String? token = _token;
    final int? userId = _userId;
    if (token == null || token.isEmpty || userId == null) {
      Get.offAllNamed('/login');
      return;
    }
    if (_sentFriendRequests.contains(friendId)) return;

    setState(() {
      _loading = true;
    });

    try {
      final Uri url = Uri.parse('$_baseUrl/api/friend/add');
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({'userId': userId, 'friendId': friendId}),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = '添加好友失败';
        try {
          final dynamic decoded = jsonDecode(res.body);
          if (decoded is Map && (decoded['message'] ?? '').toString().trim().isNotEmpty) {
            msg = (decoded['message'] ?? '').toString().trim();
          }
        } catch (_) {}
        Get.snackbar('错误', msg);
        return;
      }
      Get.snackbar('成功', '已发送好友申请');
      setState(() {
        _sentFriendRequests.add(friendId);
      });
    } catch (_) {
      Get.snackbar('错误', '添加好友失败');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  String _displayName(Map<String, dynamic> u) {
    final String nickname = (u['nickname'] ?? u['displayName'] ?? '').toString().trim();
    final String username = (u['username'] ?? u['name'] ?? '').toString().trim();
    if (nickname.isNotEmpty) return nickname;
    if (username.isNotEmpty) return username;
    final String id = (u['id'] ?? '').toString().trim();
    return id.isNotEmpty ? 'ID:$id' : '未知用户';
  }

  Uint8List? _avatarBytes(Map<String, dynamic> u) {
    final String avatar = (u['avatar'] ?? '').toString().trim();
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

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('搜索用户'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: const InputDecoration(
                      hintText: '输入用户名',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _loading ? null : _search,
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? const Center(child: Text('暂无结果'))
                    : ListView.separated(
                        itemCount: _results.length,
                        separatorBuilder: (_, index) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final Map<String, dynamic> u = _results[index];
                          final int? id = int.tryParse((u['id'] ?? '').toString());
                          final String username = (u['username'] ?? u['name'] ?? '').toString().trim();
                          final String displayName = _displayName(u);
                          final Uint8List? avatarBytes = _avatarBytes(u);
                          final bool isMe = id != null && id == _userId;
                          final bool sent = id != null && _sentFriendRequests.contains(id);

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: const Color(0xFF1A1F2E),
                              foregroundImage:
                                  avatarBytes == null ? null : MemoryImage(avatarBytes),
                              child: Text(
                                displayName.characters.first.toUpperCase(),
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(displayName),
                            subtitle: (username.isNotEmpty && displayName != username)
                                ? Text('账号：$username')
                                : null,
                            trailing: (id == null || isMe)
                                ? null
                                : ElevatedButton(
                                    onPressed:
                                        (_loading || sent) ? null : () => _addFriend(id),
                                    child: Text(sent ? '已发送' : '添加好友'),
                                  ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
