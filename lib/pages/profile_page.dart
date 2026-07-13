import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'security_page.dart';
import '../services/call_service.dart';
import '../services/signal_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  String? _token;
  int? _userId;

  String _nickname = '未登录';
  String _accountName = '';
  String? _avatarPath;
  String? _avatarData;

  double _fontScale = 1.0;
  String _appVersionText = '';

  @override
  void initState() {
    super.initState();
    _loadLocal();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      final String v = info.version;
      final String b = info.buildNumber;
      if (!mounted) return;
      setState(() {
        _appVersionText = b.isEmpty ? 'v$v' : 'v$v+$b';
      });
    } catch (_) {}
  }

  Future<void> _loadLocal() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final int? userId = (int.tryParse((prefs.get('userId') ?? '').toString()));
    final String usernameFromToken = token == null ? '' : _usernameFromJwt(token);
    final String accountName = usernameFromToken.isNotEmpty
        ? usernameFromToken
        : (userId == null ? '' : 'ID:$userId');
    final String nickname = (prefs.getString('nickname') ?? '').trim();
    final String? avatarPath = prefs.getString('avatarPath');
    final String? avatarData = prefs.getString('avatarData');
    final double scale = double.tryParse(prefs.getString('fontScale') ?? '') ?? 1.0;

    setState(() {
      _token = token;
      _userId = userId;
      _accountName = accountName;
      _nickname = nickname.isNotEmpty ? nickname : (accountName.isNotEmpty ? accountName : '未登录');
      _avatarPath = avatarPath;
      _avatarData = avatarData;
      _fontScale = scale.clamp(0.85, 1.30);
    });

    if (token != null && token.isNotEmpty && userId != null) {
      _fetchRemoteProfile();
    }
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

  Future<void> _showAvatarMenu() async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('从相册选择'),
                onTap: () => Navigator.of(context).pop('gallery'),
              ),
              ListTile(
                title: const Text('拍照'),
                onTap: () => Navigator.of(context).pop('camera'),
              ),
              ListTile(
                title: const Text('取消'),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      },
    );

    if (action == null) return;
    if (action == 'gallery') {
      await _pickAvatar(ImageSource.gallery);
    } else if (action == 'camera') {
      await _pickAvatar(ImageSource.camera);
    }
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final XFile? file = await ImagePicker().pickImage(
      source: source,
      maxWidth: 256,
      imageQuality: 60,
    );
    if (file == null) return;

    final String path = file.path;
    final String? data = await _toDataImagePayload(file);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('avatarPath', path);
    if (data != null && data.isNotEmpty) {
      await prefs.setString('avatarData', data);
    }
    setState(() {
      _avatarPath = path;
      if (data != null && data.isNotEmpty) {
        _avatarData = data;
      }
    });

    await _syncProfile();
  }

  Future<void> _editNickname() async {
    final TextEditingController controller =
        TextEditingController(text: _nickname == '未登录' ? '' : _nickname);
    final String? next = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('编辑昵称'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: '请输入昵称'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (next == null) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (next.isEmpty) {
      await prefs.remove('nickname');
    } else {
      await prefs.setString('nickname', next);
    }
    setState(() {
      _nickname = next.isNotEmpty ? next : (_accountName.isNotEmpty ? _accountName : '未登录');
    });

    await _syncProfile();
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
              children: lines.map((t) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $t'),
              )).toList(),
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

  Future<void> _pickFontScale() async {
    final double? next = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('小'),
                trailing: _fontScale == 0.9 ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(0.9),
              ),
              ListTile(
                title: const Text('中'),
                trailing: _fontScale == 1.0 ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(1.0),
              ),
              ListTile(
                title: const Text('大'),
                trailing: _fontScale == 1.1 ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(1.1),
              ),
              ListTile(
                title: const Text('超大'),
                trailing: _fontScale == 1.2 ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(1.2),
              ),
            ],
          ),
        );
      },
    );

    if (next == null) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('fontScale', next.toStringAsFixed(2));
    setState(() {
      _fontScale = next;
    });
  }

  Future<void> _confirmLogout() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('退出登录'),
          content: const Text('确认退出当前账号？'),
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

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('userId');
    try {
      await SignalService.instance.disconnect();
    } catch (_) {}
    try {
      await CallService.instance.leaveChannel();
    } catch (_) {}
    Get.offAllNamed('/login');
  }

  Future<void> _deleteAccount() async {
    final int? userId = _userId;
    final String? token = _token;
    if (userId == null || token == null || token.isEmpty) {
      Get.offAllNamed('/login');
      return;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('注销账号'),
          content: const Text('注销后所有数据将被永久删除'),
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

    final Uri url = Uri.parse('$_baseUrl/api/admin/accounts/$userId');
    final http.Response res = await http.delete(
      url,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('失败', '注销账号失败');
      return;
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('userId');
    await prefs.remove('nickname');
    await prefs.remove('avatarPath');
    await prefs.remove('avatarData');
    try {
      await SignalService.instance.disconnect();
    } catch (_) {}
    try {
      await CallService.instance.leaveChannel();
    } catch (_) {}
    Get.offAllNamed('/login');
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_token ?? ''}',
    };
  }

  Future<void> _fetchRemoteProfile() async {
    final String? token = _token;
    final int? userId = _userId;
    if (token == null || token.isEmpty || userId == null) return;
    try {
      final Uri url = Uri.parse('$_baseUrl/api/user/profile');
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) return;
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final dynamic decoded = jsonDecode(res.body);
      final dynamic data = decoded is Map<String, dynamic> ? decoded['data'] : null;
      if (data is! Map) return;
      final String remoteNickname = (data['nickname'] ?? '').toString().trim();
      final String remoteAvatar = (data['avatar'] ?? '').toString().trim();
      final SharedPreferences prefs = await SharedPreferences.getInstance();

      if (remoteNickname.isEmpty) {
        await prefs.remove('nickname');
      } else {
        await prefs.setString('nickname', remoteNickname);
      }
      if (remoteAvatar.isEmpty) {
        await prefs.remove('avatarData');
      } else {
        await prefs.setString('avatarData', remoteAvatar);
      }

      if (!mounted) return;
      setState(() {
        _nickname = remoteNickname.isNotEmpty
            ? remoteNickname
            : (_accountName.isNotEmpty ? _accountName : _nickname);
        _avatarData = remoteAvatar.isNotEmpty ? remoteAvatar : _avatarData;
      });
    } catch (_) {}
  }

  Future<void> _syncProfile() async {
    final String? token = _token;
    final int? userId = _userId;
    if (token == null || token.isEmpty || userId == null) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String nickname = (prefs.getString('nickname') ?? '').trim();
      final String avatar = (prefs.getString('avatarData') ?? '').trim();
      final Uri url = Uri.parse('$_baseUrl/api/user/profile/update');
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({
          'nickname': nickname,
          'avatar': avatar,
        }),
      );
      if (res.statusCode == 401) {
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        try {
          final dynamic decoded = jsonDecode(res.body);
          final String msg = decoded is Map<String, dynamic>
              ? (decoded['message'] ?? '').toString()
              : '';
          if (msg.isNotEmpty) {
            Get.snackbar('失败', msg);
          } else {
            Get.snackbar('失败', '保存失败');
          }
        } catch (_) {
          Get.snackbar('失败', '保存失败');
        }
        return;
      }
    } catch (_) {}
  }

  Future<String?> _toDataImagePayload(XFile file) async {
    try {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      final String name = file.name.isNotEmpty ? file.name : file.path;
      final String ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      final String mime = switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'jpeg' => 'image/jpeg',
        'jpg' => 'image/jpeg',
        _ => 'image/jpeg',
      };
      return 'data:$mime;base64,${base64Encode(bytes)}';
    } catch (_) {
      return null;
    }
  }

  Uint8List? _decodeDataImagePayload(String text) {
    final String t = text.trim();
    if (!t.startsWith('data:image/')) return null;
    final int idx = t.indexOf(';base64,');
    if (idx < 0) return null;
    final String b64 = t.substring(idx + ';base64,'.length);
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Widget _avatarWidget() {
    final String? data = _avatarData;
    if (data != null && data.isNotEmpty) {
      final Uint8List? bytes = _decodeDataImagePayload(data);
      if (bytes != null) {
        return ClipOval(
          child: Image.memory(
            bytes,
            width: 76,
            height: 76,
            fit: BoxFit.cover,
          ),
        );
      }
    }

    final String? path = _avatarPath;
    if (path == null || path.isEmpty) {
      return Container(
        width: 76,
        height: 76,
        alignment: Alignment.center,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF1A1F2E),
        ),
        child: Text(
          _nickname.characters.first.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 22,
          ),
        ),
      );
    }

    if (kIsWeb) {
      return ClipOval(
        child: Image.network(
          path,
          width: 76,
          height: 76,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              width: 76,
              height: 76,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF1A1F2E),
              ),
              child: const Icon(Icons.person, color: Colors.white),
            );
          },
        ),
      );
    }

    return FutureBuilder<Uint8List>(
      future: XFile(path).readAsBytes(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Container(
            width: 76,
            height: 76,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1A1F2E),
            ),
            child: const Icon(Icons.person, color: Colors.white),
          );
        }
        if (!snap.hasData) {
          return Container(
            width: 76,
            height: 76,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF1A1F2E),
            ),
            child: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        return ClipOval(
          child: Image.memory(
            snap.data!,
            width: 76,
            height: 76,
            fit: BoxFit.cover,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData mq = MediaQuery.of(context);
    final MediaQueryData scaled =
        mq.copyWith(textScaler: TextScaler.linear(_fontScale));

    return MediaQuery(
      data: scaled,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('我的'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F131E),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(20),
                  top: Radius.circular(16),
                ),
                border: Border.all(color: const Color(0xFF1A1F2E)),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: _showAvatarMenu,
                    child: Container(
                      width: 80,
                      height: 80,
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFB8960C),
                          width: 2,
                        ),
                      ),
                      child: _avatarWidget(),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: _editNickname,
                          child: Text(
                            _nickname,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE8E8E8),
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _accountName.isEmpty ? '未登录' : _accountName,
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
                ],
              ),
            ),
            const SizedBox(height: 12),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.security_outlined, color: Color(0xFFB8960C)),
                title: const Text(
                  '账号安全',
                  style: TextStyle(color: Color(0xFFE8E8E8), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: () => Get.to(() => const SecurityPage()),
              ),
            ),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.privacy_tip_outlined, color: Color(0xFFB8960C)),
                title: const Text(
                  '隐私政策',
                  style: TextStyle(color: Color(0xFFE8E8E8), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: () => _showTextDialog('隐私政策', const [
                  '仅收集最小权限（麦克风、相机、相册）',
                  '消息端到端加密',
                  '不收集定位、通讯录、支付信息',
                  '可随时注销账号',
                ]),
              ),
            ),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.description_outlined, color: Color(0xFFB8960C)),
                title: const Text(
                  '用户协议',
                  style: TextStyle(color: Color(0xFFE8E8E8), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: () => _showTextDialog('用户协议', const [
                  '禁止诈骗、赌博、传播违法信息等',
                  '违规将永久封禁并上报监管部门',
                  '本软件仅提供加密通讯通道',
                ]),
              ),
            ),
            _settingsCard(
              child: const ListTile(
                leading: Icon(Icons.dark_mode_outlined, color: Color(0xFF8B8B8B)),
                title: Text(
                  '深色模式',
                  style: TextStyle(color: Color(0xFF8B8B8B), fontSize: 15),
                ),
                trailing: Text(
                  '默认深色',
                  style: TextStyle(color: Color(0xFF555555)),
                ),
              ),
            ),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.text_fields, color: Color(0xFFB8960C)),
                title: const Text(
                  '字体大小',
                  style: TextStyle(color: Color(0xFFE8E8E8), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: _pickFontScale,
              ),
            ),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.logout, color: Color(0xFFB8960C)),
                title: const Text(
                  '退出登录',
                  style: TextStyle(color: Color(0xFFFF9800), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: _confirmLogout,
              ),
            ),
            _settingsCard(
              child: ListTile(
                leading: const Icon(Icons.person_off_outlined, color: Color(0xFFB8960C)),
                title: const Text(
                  '注销账号',
                  style: TextStyle(color: Color(0xFFC62828), fontSize: 15),
                ),
                trailing: const Icon(Icons.chevron_right, color: Color(0xFF555555)),
                onTap: _deleteAccount,
              ),
            ),
            const SizedBox(height: 18),
            Center(
              child: Text(
                _appVersionText.isEmpty ? 'v1.0.0' : _appVersionText,
                style: const TextStyle(color: Color(0xFF555555), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _settingsCard({required Widget child}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F131E),
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
        child: child,
      ),
    );
  }
}
