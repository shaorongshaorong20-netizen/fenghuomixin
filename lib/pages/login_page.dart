import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../services/signal_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _accountController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isLoading = false;
  bool _agreed = false;

  @override
  void dispose() {
    _accountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _postLogin({
    required Map<String, dynamic> body,
  }) async {
    final Uri url = Uri.parse('https://fenghuomixin.online/api/auth/login');
    final http.Response res = await http.post(
      url,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 12));

    Map<String, dynamic> jsonBody;
    try {
      final dynamic decoded = jsonDecode(res.body);
      jsonBody = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      jsonBody = <String, dynamic>{};
    }

    if (res.statusCode >= 200 && res.statusCode < 300) {
      return jsonBody;
    }

    final String message =
        (jsonBody['message'] ?? jsonBody['error'] ?? '登录失败').toString();
    throw Exception(message);
  }

  String? _extractToken(Map<String, dynamic> json) {
    final dynamic token = json['token'] ??
        json['accessToken'] ??
        (json['data'] is Map ? (json['data'] as Map)['token'] : null) ??
        (json['data'] is Map ? (json['data'] as Map)['accessToken'] : null);
    if (token is String && token.isNotEmpty) return token;
    return null;
  }

  String? _extractUserId(Map<String, dynamic> json) {
    final dynamic userId =
        json['userId'] ??
        json['id'] ??
        (json['data'] is Map ? (json['data'] as Map)['userId'] : null) ??
        (json['data'] is Map ? (json['data'] as Map)['id'] : null) ??
        (json['user'] is Map ? (json['user'] as Map)['id'] : null) ??
        (json['data'] is Map && (json['data'] as Map)['user'] is Map
            ? ((json['data'] as Map)['user'] as Map)['id']
            : null);
    if (userId == null) return null;
    return userId.toString();
  }

  Future<void> _login() async {
    final String account = _accountController.text.trim();
    final String password = _passwordController.text;

    if (account.isEmpty || password.isEmpty) {
      Get.snackbar('提示', '请输入账号和密码');
      return;
    }
    if (!_agreed) {
      Get.snackbar('提示', '请先阅读并同意用户协议与隐私政策');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      Map<String, dynamic> result;
      try {
        result = await _postLogin(
          body: {'username': account, 'password': password},
        );
      } catch (_) {
        result = await _postLogin(
          body: {'account': account, 'password': password},
        );
      }

      final String? token = _extractToken(result);
      final String? userId = _extractUserId(result);

      if (token == null || token.isEmpty || userId == null || userId.isEmpty) {
        throw Exception('登录返回数据异常');
      }

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', token);
      await prefs.setString('userId', userId);

      try {
        await SignalService.instance.connect();
      } catch (_) {}
      Get.offAllNamed('/');
    } on TimeoutException {
      Get.snackbar('登录失败', '网络超时，请稍后重试');
    } catch (e) {
      Get.snackbar('登录失败', e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final InputDecoration decoration = InputDecoration(
      filled: true,
      fillColor: const Color(0xFF141825),
      labelStyle: const TextStyle(color: Color(0xFF8B8B8B)),
      floatingLabelStyle: const TextStyle(color: Color(0xFFB8960C)),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Color(0xFF1A1F2E)),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Color(0xFF1A1F2E)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
        borderSide: BorderSide(color: Color(0xFFB8960C), width: 1),
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      body: Stack(
        children: [
          Positioned.fill(
            child: Image.asset(
              'assets/images/login_bg.png',
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xFF080C14)),
                );
              },
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ClipRRect(
                  borderRadius: const BorderRadius.all(Radius.circular(20)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        border: Border.all(
                          color: const Color(0xFFB8960C),
                          width: 1,
                        ),
                        borderRadius: const BorderRadius.all(Radius.circular(20)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            '烽火密信',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 8,
                              color: Color(0xFFB8960C),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '加密通讯',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xFF8B8B8B),
                            ),
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _accountController,
                            textInputAction: TextInputAction.next,
                            keyboardType: TextInputType.text,
                            style: const TextStyle(color: Color(0xFFE8E8E8)),
                            decoration: decoration.copyWith(labelText: '账号'),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            onSubmitted: (_) {
                              if (!_isLoading) {
                                _login();
                              }
                            },
                            style: const TextStyle(color: Color(0xFFE8E8E8)),
                            decoration: decoration.copyWith(
                              labelText: '密码',
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                  color: const Color(0xFF8B8B8B),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          SizedBox(
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _login,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFFC62828),
                                foregroundColor: Colors.white,
                                shape: const RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.all(Radius.circular(12)),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              child: Text(_isLoading ? '登录中...' : '登录'),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Checkbox(
                                value: _agreed,
                                onChanged: (v) {
                                  setState(() {
                                    _agreed = v == true;
                                  });
                                },
                                activeColor: const Color(0xFFB8960C),
                                checkColor: const Color(0xFF080C14),
                                side: const BorderSide(color: Color(0xFF8B8B8B)),
                              ),
                              Expanded(
                                child: Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    const Text(
                                      '我已阅读并同意',
                                      style: TextStyle(
                                        color: Color(0xFF8B8B8B),
                                        fontSize: 12,
                                        height: 1.5,
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () {
                                        _showTextDialog(
                                          '用户协议',
                                          const [
                                            '禁止发布违法、暴力、色情、诈骗、侵权等内容',
                                            '禁止骚扰、威胁他人或传播恶意信息',
                                            '违规将删除内容并可能永久封禁账号',
                                            '用户对其发布内容承担相应责任',
                                          ],
                                        );
                                      },
                                      child: const Text(
                                        '《用户协议》',
                                        style: TextStyle(
                                          color: Color(0xFFB8960C),
                                          fontSize: 12,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                    const Text(
                                      '和',
                                      style: TextStyle(
                                        color: Color(0xFF8B8B8B),
                                        fontSize: 12,
                                        height: 1.5,
                                      ),
                                    ),
                                    InkWell(
                                      onTap: () {
                                        _showTextDialog(
                                          '隐私政策',
                                          const [
                                            '仅收集提供服务所需的最小信息',
                                            '相册/相机权限用于发送图片消息',
                                            '麦克风权限用于语音通话',
                                            '可随时注销账号并删除数据',
                                          ],
                                        );
                                      },
                                      child: const Text(
                                        '《隐私政策》',
                                        style: TextStyle(
                                          color: Color(0xFFB8960C),
                                          fontSize: 12,
                                          height: 1.5,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showTextDialog(String title, List<String> lines) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: lines
                  .map(
                    (t) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('• $t'),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
