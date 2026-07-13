import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  bool _loading = true;
  String _username = '';
  String _lastLogin = '';
  String? _token;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _usernameFromJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return '';
      final String payload = parts[1];
      final String normalized = base64Url.normalize(payload);
      final String decoded = utf8.decode(base64Url.decode(normalized));
      final dynamic json = jsonDecode(decoded);
      if (json is! Map<String, dynamic>) return '';
      return (json['username'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
    });

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    _token = token;

    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
      });
      Get.offAllNamed('/login');
      return;
    }

    final String username = _usernameFromJwt(token);

    try {
      final Uri url = Uri.parse('$_baseUrl/api/user/profile');
      final http.Response res = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }

      if (res.statusCode >= 200 && res.statusCode < 300) {
        final dynamic decoded = jsonDecode(res.body);
        final Map<String, dynamic> json =
            decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
        final Map<String, dynamic> data =
            json['data'] is Map<String, dynamic> ? json['data'] : json;
        final String lastLogin = (data['last_login'] ??
                data['lastLogin'] ??
                data['last_login_at'] ??
                '')
            .toString();

        setState(() {
          _username = username;
          _lastLogin = lastLogin;
        });
      } else {
        setState(() {
          _username = username;
          _lastLogin = '';
        });
      }
    } catch (_) {
      setState(() {
        _username = username;
        _lastLogin = '';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _changePassword() async {
    final String? token = _token;
    if (token == null || token.isEmpty) {
      Get.offAllNamed('/login');
      return;
    }

    final TextEditingController oldCtrl = TextEditingController();
    final TextEditingController newCtrl = TextEditingController();
    final TextEditingController confirmCtrl = TextEditingController();

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('修改密码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: oldCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '旧密码'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: confirmCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: '确认新密码'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('确认'),
            ),
          ],
        );
      },
    );

    if (ok != true) return;

    final String oldPassword = oldCtrl.text;
    final String newPassword = newCtrl.text;
    final String confirmPassword = confirmCtrl.text;

    if (oldPassword.isEmpty || newPassword.isEmpty || confirmPassword.isEmpty) {
      Get.snackbar('提示', '请完整填写');
      return;
    }
    if (newPassword != confirmPassword) {
      Get.snackbar('提示', '两次新密码不一致');
      return;
    }

    try {
      final Uri url = Uri.parse('$_baseUrl/api/user/change-password');
      final http.Response res = await http.post(
        url,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'oldPassword': oldPassword, 'newPassword': newPassword}),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode >= 200 && res.statusCode < 300) {
        Get.snackbar('成功', '密码已更新');
        return;
      }

      String message = '修改失败';
      try {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) {
          message = (decoded['message'] ?? decoded['error'] ?? message).toString();
        }
      } catch (_) {}
      Get.snackbar('失败', message);
    } catch (_) {
      Get.snackbar('失败', '修改失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1321),
      appBar: AppBar(
        title: const Text('账号安全'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A2E),
                    borderRadius: const BorderRadius.all(Radius.circular(16)),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '当前账号',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _username.isEmpty ? '未知' : _username,
                        style: const TextStyle(color: Color(0xFFB0B0B0)),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '最后登录时间',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _lastLogin.isEmpty ? '暂无' : _lastLogin,
                        style: const TextStyle(color: Color(0xFFB0B0B0)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 46,
                  child: ElevatedButton(
                    onPressed: _changePassword,
                    child: const Text('修改密码'),
                  ),
                ),
              ],
            ),
    );
  }
}
