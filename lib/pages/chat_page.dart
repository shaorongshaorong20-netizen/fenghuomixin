import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, compute, defaultTargetPlatform, TargetPlatform;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';

import '../services/call_state.dart';
import '../services/signal_service.dart';
import '../utils/image_compress.dart';

class ChatPage extends StatefulWidget {
  final int peerId;
  final String peerUsername;

  const ChatPage({super.key, required this.peerId, required this.peerUsername});

  static Widget fromRoute() {
    int? peerId;
    String peerUsername = '';

    final params = Get.parameters;
    peerId ??= int.tryParse(
      (params['peerId'] ?? params['id'] ?? '').toString(),
    );
    peerUsername = (params['peerUsername'] ?? params['username'] ?? '')
        .toString();

    final dynamic args = Get.arguments;
    if (peerId == null && args is Map) {
      peerId ??= int.tryParse((args['peerId'] ?? args['id'] ?? '').toString());
      if (peerUsername.isEmpty) {
        peerUsername = (args['peerUsername'] ?? args['username'] ?? '')
            .toString();
      }
    }

    if (peerId == null) {
      return const _ChatRouteErrorPage();
    }

    return ChatPage(
      peerId: peerId,
      peerUsername: peerUsername.isEmpty ? '聊天' : peerUsername,
    );
  }

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatRouteErrorPage extends StatelessWidget {
  const _ChatRouteErrorPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: Text('参数错误')));
  }
}

class _ChatPageState extends State<ChatPage> {
  static const String _baseUrl = 'https://fenghuomixin.online';
  static const int _pageSize = 50;
  static const String _localSendStatusSending = 'sending';
  static const String _localSendStatusSent = 'sent';
  static const String _localSendStatusFailed = 'failed';
  static const MethodChannel _galleryChannel = MethodChannel('fenghuo/gallery');
  static const MethodChannel _windowsChatDropChannel = MethodChannel(
    'fenghuo/windows_chat_drop',
  );

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  Timer? _timer;
  bool _loading = true;
  bool _fetching = false;
  int _lastMarkedMessageId = 0;
  int _maxMessageId = 0;
  String _messageSignature = '';
  final Map<int, Uint8List> _imageBytesByMessageId = <int, Uint8List>{};
  final Map<int, String> _pendingImagePayloadByMessageId = <int, String>{};
  bool _decodingImages = false;
  int _suspendPollCount = 0;
  int _minMessageId = 0;
  bool _loadingOlder = false;
  bool _reachedStart = false;
  bool _calling = false;

  String? _token;
  int? _userId;
  List<Map<String, dynamic>> _messages = [];
  List<Map<String, dynamic>> _localOutgoingMessages = [];
  String _peerDisplayName = '';
  bool _iBlocked = false;
  bool _blockedMe = false;
  int? _replyToId;
  String? _replyPreview;
  Uint8List? _pendingDroppedImageBytes;
  String? _pendingDroppedImagePayload;
  String? _pendingDroppedImageName;
  final Map<int, GlobalKey> _messageKeys = <int, GlobalKey>{};
  int _nextLocalMessageId = -1;

  @override
  void initState() {
    super.initState();
    _peerDisplayName = SignalService.instance.displayNameForPeer(
      widget.peerId,
      fallback: widget.peerUsername,
    );
    CallState.isInCall.addListener(_handleCallStateChanged);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _windowsChatDropChannel.setMethodCallHandler(
        _handleWindowsDropMethodCall,
      );
    }
    _scrollController.addListener(_handleScroll);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final int? userId = (int.tryParse((prefs.get('userId') ?? '').toString()));

    _token = token;
    _userId = userId;

    if (token == null || token.isEmpty || userId == null) {
      Get.offAllNamed('/login');
      return;
    }

    SignalService.instance.setActivePeer(widget.peerId);
    SignalService.instance.clearUnreadForPeer(widget.peerId);

    unawaited(_fetchBlockStatus());
    _fetchPeerProfile();
    await _fetchMessages(forceFull: true);
    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(force: true);
    });
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _scrollToBottom(force: true);
    });
    Future<void>.delayed(const Duration(milliseconds: 420), () {
      if (!mounted) return;
      _scrollToBottom(force: true);
    });
    _startMessagePolling();
  }

  void _startMessagePolling() {
    if (_timer != null) return;
    if (CallState.isInCall.value) return;
    if ((_token ?? '').isEmpty || _userId == null) return;
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _fetchMessages(),
    );
  }

  void _stopMessagePolling() {
    _timer?.cancel();
    _timer = null;
  }

  void _handleCallStateChanged() {
    if (CallState.isInCall.value) {
      _stopMessagePolling();
      return;
    }
    _startMessagePolling();
  }

  Future<void> _fetchBlockStatus() async {
    final String? token = _token;
    final int? userId = _userId;
    if (token == null || token.isEmpty || userId == null) return;
    try {
      final Uri url = Uri.parse(
        '$_baseUrl/api/block/status',
      ).replace(queryParameters: {'peerId': widget.peerId.toString()});
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final dynamic decoded = jsonDecode(res.body);
      final bool iBlocked = decoded is Map
          ? (decoded['iBlocked'] == true)
          : false;
      final bool blockedMe = decoded is Map
          ? (decoded['blockedMe'] == true)
          : false;
      if (!mounted) return;
      setState(() {
        _iBlocked = iBlocked;
        _blockedMe = blockedMe;
      });
    } catch (_) {}
  }

  Future<void> _toggleBlock() async {
    final String? token = _token;
    final int? userId = _userId;
    if (token == null || token.isEmpty || userId == null) return;
    try {
      final bool nextBlock = !_iBlocked;
      final Uri url = Uri.parse(
        nextBlock ? '$_baseUrl/api/block' : '$_baseUrl/api/unblock',
      );
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({'blockedId': widget.peerId}),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = '操作失败';
        try {
          final dynamic decoded = jsonDecode(res.body);
          if (decoded is Map &&
              (decoded['message'] ?? '').toString().trim().isNotEmpty) {
            msg = (decoded['message'] ?? '').toString().trim();
          }
        } catch (_) {}
        Get.snackbar('错误', msg);
        return;
      }
      if (!mounted) return;
      setState(() {
        _iBlocked = nextBlock;
      });
      Get.snackbar('成功', nextBlock ? '已拉黑该用户' : '已解除拉黑');
    } catch (e) {
      Get.snackbar('错误', e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _reportMessage(Map<String, dynamic> msg) async {
    final int messageId =
        int.tryParse(
          (msg['id'] ?? msg['message_id'] ?? msg['messageId'] ?? '').toString(),
        ) ??
        0;
    if (messageId <= 0) return;
    final bool isRevoked =
        (msg['is_revoked'] ?? msg['isRevoked'] ?? 0).toString() == '1';
    if (isRevoked) return;

    final TextEditingController detailCtrl = TextEditingController();
    String reason = '骚扰辱骂';
    final bool? ok = await _withPollingSuspended(() {
      return showDialog<bool>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setLocal) {
              Widget reasonItem(String text) {
                final bool selected = reason == text;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(text),
                  trailing: selected ? const Icon(Icons.check, size: 20) : null,
                  onTap: () => setLocal(() => reason = text),
                );
              }

              return AlertDialog(
                title: const Text('举报'),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      reasonItem('骚扰辱骂'),
                      reasonItem('色情低俗'),
                      reasonItem('诈骗引流'),
                      reasonItem('违法违规'),
                      reasonItem('侵权'),
                      const SizedBox(height: 10),
                      TextField(
                        controller: detailCtrl,
                        maxLines: 3,
                        maxLength: 200,
                        decoration: const InputDecoration(hintText: '补充说明（选填）'),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('提交'),
                  ),
                ],
              );
            },
          );
        },
      );
    });
    if (ok != true) return;

    try {
      final Uri url = Uri.parse('$_baseUrl/api/reports/message');
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({
          'messageId': messageId,
          'reason': reason,
          'detail': detailCtrl.text.trim(),
        }),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = '举报失败';
        try {
          final dynamic decoded = jsonDecode(res.body);
          if (decoded is Map &&
              (decoded['message'] ?? '').toString().trim().isNotEmpty) {
            msg = (decoded['message'] ?? '').toString().trim();
          }
        } catch (_) {}
        Get.snackbar('错误', msg);
        return;
      }
      Get.snackbar('成功', '已提交举报，我们会尽快处理');
    } catch (e) {
      Get.snackbar('错误', e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _handleScroll() {
    if (_loading) return;
    if (_loadingOlder) return;
    if (_fetching) return;
    if (_reachedStart) return;
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels > 120) return;
    unawaited(_fetchOlderMessages());
  }

  Future<void> _fetchOlderMessages() async {
    if (_loadingOlder) return;
    if (_fetching) return;
    if (_pollingSuspended) return;
    final int? fromId = _userId;
    if (fromId == null) return;
    if (_messages.isEmpty) return;

    int beforeId = _minMessageId;
    if (beforeId <= 0) {
      int minId = 0;
      for (final m in _messages) {
        final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
        if (id <= 0) continue;
        if (minId == 0 || id < minId) minId = id;
      }
      beforeId = minId;
    }
    if (beforeId <= 1) {
      _reachedStart = true;
      return;
    }

    _loadingOlder = true;
    try {
      final double oldPixels = _scrollController.hasClients
          ? _scrollController.position.pixels
          : 0;
      final double oldMax = _scrollController.hasClients
          ? _scrollController.position.maxScrollExtent
          : 0;

      final Uri url = Uri.parse('$_baseUrl/api/messages').replace(
        queryParameters: {
          'fromId': fromId.toString(),
          'toId': widget.peerId.toString(),
          'beforeId': beforeId.toString(),
          'limit': _pageSize.toString(),
        },
      );
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return;
      }

      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> list = decoded is Map<String, dynamic>
          ? (decoded['messages'] as List<dynamic>? ??
                decoded['data'] as List<dynamic>? ??
                [])
          : [];
      final List<Map<String, dynamic>> next = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      if (next.isEmpty) {
        _reachedStart = true;
        return;
      }

      final List<Map<String, dynamic>> prepend = <Map<String, dynamic>>[];
      int nextMin = _minMessageId > 0 ? _minMessageId : beforeId;
      for (final m in next) {
        final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
        if (id <= 0) continue;
        if (_minMessageId > 0 && id >= _minMessageId) continue;
        prepend.add(m);
        if (nextMin == 0 || id < nextMin) nextMin = id;

        final String content = (m['content'] ?? '').toString();
        if (_isDataImagePayload(content)) _enqueueImageDecode(id, content);
      }

      if (prepend.isEmpty) {
        _reachedStart = true;
        return;
      }

      _minMessageId = nextMin;
      if (next.length < _pageSize) _reachedStart = true;

      setState(() {
        _messages = <Map<String, dynamic>>[...prepend, ..._messages];
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_scrollController.hasClients) return;
        final double newMax = _scrollController.position.maxScrollExtent;
        final double delta = newMax - oldMax;
        final double target = oldPixels + (delta > 0 ? delta : 0);
        if (target >= 0) {
          try {
            _scrollController.jumpTo(target);
          } catch (_) {}
        }
      });
    } catch (_) {
    } finally {
      _loadingOlder = false;
    }
  }

  bool get _pollingSuspended => _suspendPollCount > 0;

  Future<T> _withPollingSuspended<T>(Future<T> Function() action) async {
    _suspendPollCount += 1;
    try {
      return await action();
    } finally {
      _suspendPollCount = (_suspendPollCount - 1).clamp(0, 1 << 30);
    }
  }

  void _enqueueImageDecode(int messageId, String payload) {
    if (messageId <= 0) return;
    if (_imageBytesByMessageId.containsKey(messageId)) return;
    if (_pendingImagePayloadByMessageId.containsKey(messageId)) return;
    if (!_isDataImagePayload(payload)) return;
    _pendingImagePayloadByMessageId[messageId] = payload;
    unawaited(_processImageDecodeQueue());
  }

  Future<void> _processImageDecodeQueue() async {
    if (_decodingImages) return;
    _decodingImages = true;
    try {
      while (_pendingImagePayloadByMessageId.isNotEmpty) {
        final int messageId = _pendingImagePayloadByMessageId.keys.first;
        final String payload =
            _pendingImagePayloadByMessageId.remove(messageId) ?? '';
        if (payload.isEmpty) continue;
        final Uint8List? bytes = await compute(
          _decodeDataImagePayloadCompute,
          payload,
        );
        if (bytes == null) continue;
        if (!mounted) return;
        setState(() {
          _imageBytesByMessageId[messageId] = bytes;
        });
      }
    } finally {
      _decodingImages = false;
    }
  }

  void _openImagePreview({
    required String title,
    Uint8List? bytes,
    String? url,
  }) {
    if (bytes == null && (url == null || url.trim().isEmpty)) return;

    final TransformationController transformationController =
        TransformationController();
    double currentScale = 1.0;

    void resetZoom() {
      currentScale = 1.0;
      transformationController.value = Matrix4.identity();
    }

    void applyWheelZoom(PointerScrollEvent event) {
      final double zoomFactor = event.scrollDelta.dy < 0 ? 1.12 : 0.9;
      currentScale = (currentScale * zoomFactor).clamp(1.0, 4.0).toDouble();
      transformationController.value = Matrix4.diagonal3Values(
        currentScale,
        currentScale,
        1.0,
      );
    }

    unawaited(
      _withPollingSuspended(() {
        return showDialog<void>(
          context: context,
          barrierColor: Colors.black.withValues(alpha: 0.95),
          builder: (context) {
            final Widget image = bytes != null
                ? Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  )
                : Image.network(
                    url!.trim(),
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  );

            return Material(
              color: Colors.transparent,
              child: Shortcuts(
                shortcuts: <ShortcutActivator, Intent>{
                  const SingleActivator(LogicalKeyboardKey.escape):
                      const DismissIntent(),
                },
                child: Actions(
                  actions: <Type, Action<Intent>>{
                    DismissIntent: CallbackAction<DismissIntent>(
                      onInvoke: (Intent intent) {
                        Navigator.of(context).maybePop();
                        return null;
                      },
                    ),
                  },
                  child: Focus(
                    autofocus: true,
                    child: SafeArea(
                      child: Stack(
                        children: [
                          Center(
                            child: GestureDetector(
                              onDoubleTap: resetZoom,
                              child: Listener(
                                onPointerSignal: (PointerSignalEvent event) {
                                  if (event is PointerScrollEvent) {
                                    applyWheelZoom(event);
                                  }
                                },
                                child: InteractiveViewer(
                                  transformationController:
                                      transformationController,
                                  minScale: 1.0,
                                  maxScale: 4.0,
                                  child: image,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 12,
                            top: 8,
                            child: IconButton(
                              onPressed: () => Navigator.of(context).pop(),
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 16,
                            right: 64,
                            top: 14,
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }

  String _fileNameFromPath(String path) {
    final String normalized = path.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) return '图片';
    final int index = normalized.lastIndexOf('/');
    return index >= 0 ? normalized.substring(index + 1) : normalized;
  }

  void _clearDroppedImagePreview() {
    if (_pendingDroppedImagePayload == null &&
        _pendingDroppedImageBytes == null &&
        (_pendingDroppedImageName == null ||
            _pendingDroppedImageName!.isEmpty)) {
      return;
    }
    setState(() {
      _pendingDroppedImageBytes = null;
      _pendingDroppedImagePayload = null;
      _pendingDroppedImageName = null;
    });
  }

  Future<void> _confirmSendDroppedImage() async {
    final String? payload = _pendingDroppedImagePayload?.trim();
    if (payload == null || payload.isEmpty) return;
    _clearDroppedImagePreview();
    await _sendImagePayload(payload);
  }

  void _showDroppedImagePreview({
    required Uint8List bytes,
    required String payload,
    required String fileName,
  }) {
    setState(() {
      _pendingDroppedImageBytes = bytes;
      _pendingDroppedImagePayload = payload;
      _pendingDroppedImageName = fileName;
    });
  }

  Widget _buildDroppedImagePreviewCard() {
    final Uint8List? bytes = _pendingDroppedImageBytes;
    final String? payload = _pendingDroppedImagePayload;
    if (bytes == null || bytes.isEmpty || payload == null || payload.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF141825),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        border: Border.all(color: const Color(0xFF1A1F2E), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            child: SizedBox(
              width: 56,
              height: 56,
              child: Image.memory(bytes, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (_pendingDroppedImageName ?? '图片').trim().isEmpty
                      ? '图片'
                      : _pendingDroppedImageName!.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFE8E8E8),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '拖拽图片预览',
                  style: TextStyle(color: Color(0xFF8B8B8B), fontSize: 11),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: _confirmSendDroppedImage,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFB8960C),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('发送'),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: _clearDroppedImagePreview,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF8B8B8B),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _mimeFromUrl(String url) {
    final String p = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.gif')) return 'image/gif';
    if (p.endsWith('.webp')) return 'image/webp';
    if (p.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  String _mimeFromDataPayload(String payload) {
    final String t = payload.trim();
    if (!t.startsWith('data:image/')) return 'image/jpeg';
    final int comma = t.indexOf(',');
    final String header = comma > 0 ? t.substring(0, comma) : t;
    final int semi = header.indexOf(';');
    final String mime =
        (semi > 0 ? header.substring(5, semi) : header.substring(5)).trim();
    return mime.startsWith('image/') ? mime : 'image/jpeg';
  }

  String _formatBubbleTime(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return '';
    DateTime? dt = DateTime.tryParse(text);
    dt ??= DateTime.tryParse(text.replaceFirst(' ', 'T'));
    if (dt == null) return '';
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  String _sendStatusText(String raw) {
    return switch (raw) {
      _localSendStatusSending => '发送中…',
      _localSendStatusSent => '✓',
      _localSendStatusFailed => '发送失败',
      _ => '',
    };
  }

  Color _sendStatusColor(String raw) {
    return switch (raw) {
      _localSendStatusFailed => const Color(0xFFD98F8F),
      _ => const Color(0xFF6F7785),
    };
  }

  Future<String?> _saveImageBytesToGallery(
    Uint8List bytes, {
    required String mime,
  }) async {
    final String name = 'fenghuo_${DateTime.now().millisecondsSinceEpoch}';
    try {
      final String? uri = await _galleryChannel.invokeMethod<String>(
        'saveImage',
        <String, dynamic>{'bytes': bytes, 'name': name, 'mime': mime},
      );
      return uri;
    } on PlatformException catch (e) {
      throw Exception(e.message ?? '保存失败');
    }
  }

  Future<void> _saveChatImageToGallery({
    required String title,
    Uint8List? bytes,
    String? url,
    String? mime,
  }) async {
    if (kIsWeb) {
      Get.snackbar('提示', 'Web 端暂不支持保存图片');
      return;
    }
    Uint8List? data = bytes;
    final String? normalizedUrl = url?.trim().isEmpty == true
        ? null
        : url?.trim();

    try {
      if (data == null) {
        if (normalizedUrl == null) {
          Get.snackbar('失败', '图片数据不存在');
          return;
        }
        final Uri? uri = Uri.tryParse(normalizedUrl);
        if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
          Get.snackbar('失败', '图片链接无效');
          return;
        }
        Get.snackbar('提示', '图片保存中...');
        final http.Response res = await http.get(uri);
        if (res.statusCode < 200 || res.statusCode >= 300) {
          Get.snackbar('失败', '下载图片失败(${res.statusCode})');
          return;
        }
        data = res.bodyBytes;
      }

      if (data == null || data.isEmpty) {
        Get.snackbar('失败', '图片数据为空');
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          await Permission.storage.request();
        } catch (_) {}
      }

      final String effectiveMime = (mime ?? '').trim().isNotEmpty
          ? mime!.trim()
          : (normalizedUrl != null
                ? _mimeFromUrl(normalizedUrl)
                : 'image/jpeg');
      await _saveImageBytesToGallery(data, mime: effectiveMime);
      Get.snackbar('成功', '已保存到相册');
    } catch (e) {
      Get.snackbar('失败', e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _scrollToBottom({required bool force}) {
    if (!_scrollController.hasClients) return;
    final double max = _scrollController.position.maxScrollExtent;
    final double cur = _scrollController.position.pixels;
    final bool nearBottom = (max - cur) < 80;
    if (!force && !nearBottom) return;
    _scrollController.jumpTo(max);
  }

  KeyEventResult _handleWindowsEnterToSend(FocusNode node, KeyEvent event) {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
      return KeyEventResult.ignored;
    }
    if (!_inputFocusNode.hasFocus) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final LogicalKeyboardKey key = event.logicalKey;
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final TextEditingValue value = _inputController.value;
    final TextRange composing = value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      // Let the IME consume Enter while candidate composition is active.
      return KeyEventResult.ignored;
    }

    final bool shiftPressed = HardwareKeyboard.instance.isShiftPressed;
    if (shiftPressed) return KeyEventResult.ignored;

    final bool controlPressed = HardwareKeyboard.instance.isControlPressed;
    final bool altPressed = HardwareKeyboard.instance.isAltPressed;
    final bool metaPressed = HardwareKeyboard.instance.isMetaPressed;
    if (controlPressed || altPressed || metaPressed) {
      return KeyEventResult.ignored;
    }

    unawaited(_send());
    return KeyEventResult.handled;
  }

  Map<String, String> _headers() {
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${_token ?? ''}',
    };
  }

  List<Map<String, dynamic>> get _visibleMessages {
    return <Map<String, dynamic>>[..._messages, ..._localOutgoingMessages];
  }

  int _replyIdFromMessage(Map<String, dynamic> message) {
    return int.tryParse(
          (message['reply_to_id'] ?? message['replyToId'] ?? '').toString(),
        ) ??
        0;
  }

  int _appendLocalOutgoingMessage({required String content}) {
    final int localMessageId = _nextLocalMessageId--;
    final String replyPreview = (_replyPreview ?? '').trim();
    setState(() {
      _localOutgoingMessages = <Map<String, dynamic>>[
        ..._localOutgoingMessages,
        <String, dynamic>{
          'id': localMessageId,
          'sender_id': _userId,
          'content': content,
          'timestamp': DateTime.now().toIso8601String(),
          'reply_to_id': _replyToId,
          'reply_preview': replyPreview,
          'local_message_id': localMessageId,
          'local_status': _localSendStatusSending,
        },
      ];
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollToBottom(force: true);
    });
    return localMessageId;
  }

  void _updateLocalOutgoingMessage(
    int localMessageId, {
    String? status,
    String? content,
    String? timestamp,
  }) {
    if (!mounted) return;
    final int index = _localOutgoingMessages.indexWhere(
      (Map<String, dynamic> message) =>
          (message['local_message_id'] ?? '').toString() ==
          localMessageId.toString(),
    );
    if (index < 0) return;
    final Map<String, dynamic> next = Map<String, dynamic>.from(
      _localOutgoingMessages[index],
    );
    if (status != null && status.isNotEmpty) {
      next['local_status'] = status;
    }
    if (content != null && content.isNotEmpty) {
      next['content'] = content;
    }
    if (timestamp != null && timestamp.isNotEmpty) {
      next['timestamp'] = timestamp;
    }
    setState(() {
      _localOutgoingMessages[index] = next;
    });
  }

  void _markLocalOutgoingMessageFailed(int? localMessageId) {
    if (localMessageId == null) return;
    _updateLocalOutgoingMessage(localMessageId, status: _localSendStatusFailed);
  }

  void _markLocalOutgoingMessageSent(
    int? localMessageId, {
    String? content,
    String? timestamp,
  }) {
    if (localMessageId == null) return;
    _updateLocalOutgoingMessage(
      localMessageId,
      status: _localSendStatusSent,
      content: content,
      timestamp: timestamp,
    );
  }

  void _reconcileLocalOutgoingMessages(List<Map<String, dynamic>> messages) {
    if (!mounted || _localOutgoingMessages.isEmpty) return;
    final Set<int> usedServerIndexes = <int>{};
    final List<Map<String, dynamic>> remaining = <Map<String, dynamic>>[];

    for (final Map<String, dynamic> local in _localOutgoingMessages) {
      final String localStatus = (local['local_status'] ?? '').toString();
      if (localStatus != _localSendStatusSent) {
        remaining.add(local);
        continue;
      }

      final int? localSenderId = int.tryParse(
        (local['sender_id'] ?? local['senderId'] ?? '').toString(),
      );
      if (localSenderId == null || localSenderId != _userId) {
        remaining.add(local);
        continue;
      }

      final String localContent = (local['content'] ?? '').toString();
      final int localReplyToId = _replyIdFromMessage(local);
      int matchedIndex = -1;

      for (int i = 0; i < messages.length; i++) {
        if (usedServerIndexes.contains(i)) continue;
        final Map<String, dynamic> server = messages[i];
        final int? senderId = int.tryParse(
          (server['sender_id'] ?? server['senderId'] ?? '').toString(),
        );
        if (senderId == null || senderId != _userId) continue;
        if (_replyIdFromMessage(server) != localReplyToId) continue;
        if ((server['content'] ?? '').toString() != localContent) continue;
        matchedIndex = i;
        break;
      }

      if (matchedIndex >= 0) {
        usedServerIndexes.add(matchedIndex);
        continue;
      }

      remaining.add(local);
    }

    if (remaining.length == _localOutgoingMessages.length) return;
    setState(() {
      _localOutgoingMessages = remaining;
    });
  }

  void _syncMessageKeysWithMessages(List<Map<String, dynamic>> messages) {
    final Set<int> ids = <int>{};
    for (final m in messages) {
      final int id =
          int.tryParse(
            (m['id'] ?? m['message_id'] ?? m['messageId'] ?? '').toString(),
          ) ??
          0;
      if (id > 0) ids.add(id);
    }
    _messageKeys.removeWhere((key, _) => !ids.contains(key));
  }

  String _previewForQuote(Map<String, dynamic> msg) {
    final bool isRevoked =
        (msg['is_revoked'] ?? msg['isRevoked'] ?? 0).toString() == '1';
    if (isRevoked) return '已撤回';
    final String content = (msg['content'] ?? '').toString().trim();
    if (content.isEmpty) return '';
    if (_isImageMessage(content) || _isDataImagePayload(content)) return '[图片]';
    final String oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= 80) return oneLine;
    return '${oneLine.substring(0, 80)}…';
  }

  void _setReplyFromMessage(Map<String, dynamic> msg) {
    final int id =
        int.tryParse(
          (msg['id'] ?? msg['message_id'] ?? msg['messageId'] ?? '').toString(),
        ) ??
        0;
    if (id <= 0) return;
    final String preview = _previewForQuote(msg);
    setState(() {
      _replyToId = id;
      _replyPreview = preview.isEmpty ? '引用消息' : preview;
    });
    _inputFocusNode.requestFocus();
  }

  void _clearReply() {
    if (_replyToId == null &&
        (_replyPreview == null || _replyPreview!.isEmpty)) {
      return;
    }
    setState(() {
      _replyToId = null;
      _replyPreview = null;
    });
  }

  Future<void> _scrollToMessage(int messageId) async {
    final GlobalKey? key = _messageKeys[messageId];
    final BuildContext? ctx = key?.currentContext;
    if (ctx == null) {
      Get.snackbar('提示', '引用消息不在当前记录');
      return;
    }
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 260),
      alignment: 0.2,
      curve: Curves.easeInOut,
    );
  }

  Future<void> _fetchPeerProfile() async {
    final String? token = _token;
    if (token == null || token.isEmpty) return;
    try {
      final Uri url = Uri.parse(
        '$_baseUrl/api/user/public',
      ).replace(queryParameters: {'userId': widget.peerId.toString()});
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) return;
      if (res.statusCode < 200 || res.statusCode >= 300) return;
      final dynamic decoded = jsonDecode(res.body);
      final dynamic data = decoded is Map<String, dynamic>
          ? decoded['data']
          : null;
      if (data is! Map) return;
      final String nickname = (data['nickname'] ?? '').toString().trim();
      final String username = (data['username'] ?? '').toString().trim();
      final String fallback = nickname.isNotEmpty
          ? nickname
          : (username.isNotEmpty ? username : _peerDisplayName);
      final String next = SignalService.instance.displayNameForPeer(
        widget.peerId,
        fallback: fallback,
      );
      if (!mounted) return;
      setState(() {
        _peerDisplayName = next;
      });
    } catch (_) {}
  }

  Future<void> _openRemarkDialog() async {
    final TextEditingController c = TextEditingController(
      text: SignalService.instance.remarkForPeer(widget.peerId),
    );
    final String? result = await _withPollingSuspended(() {
      return showDialog<String>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('修改备注'),
            content: TextField(
              controller: c,
              autofocus: true,
              maxLength: 30,
              decoration: const InputDecoration(hintText: '仅自己可见'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(c.text),
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    });
    if (result == null) return;
    try {
      await SignalService.instance.setRemark(
        peerId: widget.peerId,
        remark: result,
      );
      if (!mounted) return;
      setState(() {
        _peerDisplayName = SignalService.instance.displayNameForPeer(
          widget.peerId,
          fallback: _peerDisplayName,
        );
      });
    } catch (e) {
      Get.snackbar('错误', e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _fetchMessages({bool forceFull = false}) async {
    if (_fetching) return;
    if (_pollingSuspended) return;
    final int? fromId = _userId;
    if (fromId == null) return;

    final bool wasAtBottom = !_scrollController.hasClients
        ? true
        : (_scrollController.position.maxScrollExtent -
                  _scrollController.position.pixels) <
              80;

    _fetching = true;
    try {
      final bool shouldFull = forceFull || _maxMessageId <= 0;
      final int afterId = shouldFull ? 0 : _maxMessageId;

      final Map<String, String> params = <String, String>{
        'fromId': fromId.toString(),
        'toId': widget.peerId.toString(),
      };
      if (afterId > 0) {
        params['afterId'] = afterId.toString();
        params['limit'] = _pageSize.toString();
      } else {
        params['limit'] = _pageSize.toString();
      }

      final Uri url = Uri.parse(
        '$_baseUrl/api/messages',
      ).replace(queryParameters: params);
      final http.Response res = await http.get(url, headers: _headers());
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return;
      }

      final dynamic decoded = jsonDecode(res.body);
      final List<dynamic> list = decoded is Map<String, dynamic>
          ? (decoded['messages'] as List<dynamic>? ??
                decoded['data'] as List<dynamic>? ??
                [])
          : [];
      final List<Map<String, dynamic>> next = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      if (!mounted) return;

      if (afterId > 0) {
        if (next.isEmpty) return;

        final List<Map<String, dynamic>> append = <Map<String, dynamic>>[];
        int nextMaxId = _maxMessageId;
        for (final m in next) {
          final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
          if (id <= nextMaxId) continue;
          append.add(m);
          if (id > nextMaxId) nextMaxId = id;

          final String content = (m['content'] ?? '').toString();
          if (_isDataImagePayload(content)) _enqueueImageDecode(id, content);
        }
        if (append.isEmpty) return;

        _maxMessageId = nextMaxId;
        if (_minMessageId == 0) {
          int minId = 0;
          for (final m in _messages) {
            final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
            if (id <= 0) continue;
            if (minId == 0 || id < minId) minId = id;
          }
          _minMessageId = minId;
        }
        final List<Map<String, dynamic>> newMessages = <Map<String, dynamic>>[
          ..._messages,
          ...append,
        ];
        setState(() {
          _messages = newMessages;
        });
        _reconcileLocalOutgoingMessages(newMessages);
        _syncMessageKeysWithMessages(newMessages);

        if (_maxMessageId > _lastMarkedMessageId) {
          _lastMarkedMessageId = _maxMessageId;
          _markRead();
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (wasAtBottom) _scrollToBottom(force: true);
        });
        return;
      }

      int maxId = 0;
      String lastTs = '';
      int revoked = 0;
      int minId = 0;
      for (final m in next) {
        final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
        if (id > maxId) maxId = id;
        if (id > 0 && (minId == 0 || id < minId)) minId = id;
        final String ts = (m['timestamp'] ?? '').toString();
        if (id == maxId && ts.isNotEmpty) lastTs = ts;
        if ((m['is_revoked'] ?? m['isRevoked'] ?? 0).toString() == '1') {
          revoked += 1;
        }
      }

      final String signature = '${next.length}_${maxId}_${lastTs}_$revoked';
      if (signature == _messageSignature) {
        if (maxId > _lastMarkedMessageId) {
          _lastMarkedMessageId = maxId;
          _markRead();
        }
        return;
      }

      _messageSignature = signature;
      _maxMessageId = maxId;
      _minMessageId = minId;
      _reachedStart = next.length < _pageSize;

      for (int i = (next.length - 1); i >= 0 && i >= next.length - 80; i--) {
        final Map<String, dynamic> m = next[i];
        final int id = int.tryParse((m['id'] ?? '').toString()) ?? 0;
        if (id <= 0) continue;
        final String content = (m['content'] ?? '').toString();
        if (_isDataImagePayload(content)) _enqueueImageDecode(id, content);
      }

      setState(() {
        _messages = next;
      });
      _reconcileLocalOutgoingMessages(next);
      _syncMessageKeysWithMessages(next);
      if (maxId > _lastMarkedMessageId) {
        _lastMarkedMessageId = maxId;
        _markRead();
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (wasAtBottom) {
          _scrollToBottom(force: true);
        }
      });
    } catch (_) {
    } finally {
      _fetching = false;
    }
  }

  Future<void> _send() async {
    final int? fromId = _userId;
    final String content = _inputController.text.trim();
    if (fromId == null || content.isEmpty) return;

    final int localMessageId = _appendLocalOutgoingMessage(content: content);
    _inputController.clear();

    await _sendContent(content, localMessageId: localMessageId);
  }

  Future<void> _openScheduleDialog() async {
    final int? fromId = _userId;
    if (fromId == null) return;

    final TextEditingController c = TextEditingController(
      text: _inputController.text,
    );
    DateTime sendAt = DateTime.now().add(const Duration(minutes: 10));

    final Map<String, dynamic>? result = await _withPollingSuspended(() {
      return showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setInnerState) {
              final String timeLabel =
                  '${sendAt.year}-${sendAt.month.toString().padLeft(2, '0')}-${sendAt.day.toString().padLeft(2, '0')} '
                  '${sendAt.hour.toString().padLeft(2, '0')}:${sendAt.minute.toString().padLeft(2, '0')}';
              return AlertDialog(
                title: const Text('定时发送'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: c,
                      minLines: 2,
                      maxLines: 4,
                      maxLength: 500,
                      decoration: const InputDecoration(hintText: '输入要定时发送的内容'),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(child: Text('发送时间：$timeLabel')),
                        TextButton(
                          onPressed: () async {
                            final BuildContext ctx = context;
                            final DateTime? d = await showDatePicker(
                              context: ctx,
                              initialDate: sendAt,
                              firstDate: DateTime.now(),
                              lastDate: DateTime.now().add(
                                const Duration(days: 365),
                              ),
                            );
                            if (!ctx.mounted) return;
                            if (d == null) return;
                            final TimeOfDay? t = await showTimePicker(
                              context: ctx,
                              initialTime: TimeOfDay.fromDateTime(sendAt),
                            );
                            if (!ctx.mounted) return;
                            if (t == null) return;
                            setInnerState(() {
                              sendAt = DateTime(
                                d.year,
                                d.month,
                                d.day,
                                t.hour,
                                t.minute,
                              );
                            });
                          },
                          child: const Text('选择'),
                        ),
                      ],
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(<String, dynamic>{
                          'content': c.text,
                          'sendAtMs': sendAt.millisecondsSinceEpoch,
                        }),
                    child: const Text('确定'),
                  ),
                ],
              );
            },
          );
        },
      );
    });

    if (result == null) return;
    final String content = (result['content'] ?? '').toString().trim();
    final int sendAtMs =
        int.tryParse((result['sendAtMs'] ?? '').toString()) ?? 0;
    if (content.isEmpty || sendAtMs <= 0) return;

    final Uri url = Uri.parse('$_baseUrl/api/messages/schedule');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({
        'toId': widget.peerId,
        'content': content,
        'sendAtMs': sendAtMs,
      }),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      String msg = '创建失败';
      try {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map &&
            (decoded['message'] ?? '').toString().isNotEmpty) {
          msg = decoded['message'].toString();
        }
      } catch (_) {}
      Get.snackbar('错误', msg);
      return;
    }

    _inputController.clear();
    Get.snackbar('成功', '已创建定时发送');
  }

  Future<void> _sendContent(String content, {int? localMessageId}) async {
    final int? fromId = _userId;
    if (fromId == null || content.isEmpty) {
      _markLocalOutgoingMessageFailed(localMessageId);
      return;
    }
    if (_iBlocked) {
      _markLocalOutgoingMessageFailed(localMessageId);
      Get.snackbar('提示', '你已拉黑该用户，无法发送消息');
      return;
    }
    if (_blockedMe) {
      _markLocalOutgoingMessageFailed(localMessageId);
      Get.snackbar('提示', '对方已拉黑你，无法发送消息');
      return;
    }

    final int? replyToId = _replyToId;
    final Map<String, dynamic> payload = <String, dynamic>{
      'fromId': fromId,
      'toId': widget.peerId,
      'content': content,
    };
    if (replyToId != null && replyToId > 0) {
      payload['replyToId'] = replyToId;
    }
    final Uri url = Uri.parse('$_baseUrl/api/messages/send');
    http.Response res;
    try {
      res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode(payload),
      );
    } catch (_) {
      _markLocalOutgoingMessageFailed(localMessageId);
      Get.snackbar('错误', '发送失败');
      return;
    }
    if (res.statusCode == 401) {
      _markLocalOutgoingMessageFailed(localMessageId);
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      _markLocalOutgoingMessageFailed(localMessageId);
      String msg = '发送失败';
      try {
        final dynamic decoded = jsonDecode(res.body);
        if (decoded is Map &&
            (decoded['message'] ?? '').toString().trim().isNotEmpty) {
          msg = (decoded['message'] ?? '').toString().trim();
        }
      } catch (_) {}
      Get.snackbar('错误', msg);
      return;
    }

    if (mounted && replyToId != null && replyToId == _replyToId) {
      _clearReply();
    }
    String sentTimestamp = '';
    try {
      final dynamic decoded = jsonDecode(res.body);
      final dynamic message = decoded is Map<String, dynamic>
          ? decoded['message']
          : null;
      final String ts = message is Map
          ? (message['timestamp'] ?? '').toString()
          : '';
      sentTimestamp = ts;
      final String preview = _isDataImagePayload(content) ? '[图片]' : content;
      SignalService.instance.updateConversationSnapshot(
        peerId: widget.peerId,
        lastMessage: preview,
        lastTime: ts.isEmpty ? null : ts,
      );
    } catch (_) {
      final String preview = _isDataImagePayload(content) ? '[图片]' : content;
      SignalService.instance.updateConversationSnapshot(
        peerId: widget.peerId,
        lastMessage: preview,
      );
    }
    _markLocalOutgoingMessageSent(
      localMessageId,
      content: content,
      timestamp: sentTimestamp.isEmpty ? null : sentTimestamp,
    );
    await _fetchMessages();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(force: true);
    });
  }

  Future<void> _markRead() async {
    final int? userId = _userId;
    if (userId == null) return;
    try {
      final Uri url = Uri.parse('$_baseUrl/api/messages/read');
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({'userId': userId, 'peerId': widget.peerId}),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
      }
    } catch (_) {}
  }

  Future<void> _pickFromGallery() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      await _pickFromFile();
      return;
    }
    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      imageQuality: 70,
    );
    if (file == null) return;

    await _sendPickedImage(file, fallbackLabel: '[图片]');
  }

  Future<void> _pickFromCamera() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      Get.snackbar('提示', '电脑端暂不支持拍摄，请从文件选择图片');
      return;
    }
    if (!kIsWeb) {
      final PermissionStatus status = await Permission.camera.request();
      if (!status.isGranted) {
        Get.snackbar('提示', '未获取相机权限');
        return;
      }
    }

    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1024,
      imageQuality: 70,
    );
    if (file == null) return;

    await _sendPickedImage(file, fallbackLabel: '[拍照]');
  }

  Future<void> _pickFromFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final PlatformFile f = result.files.first;
    final Uint8List? bytes = f.bytes;
    if (bytes == null || bytes.isEmpty) return;
    final String ext = (f.extension ?? '').toString().toLowerCase();
    final String mime = switch (ext) {
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'heic' => 'image/heic',
      'jpeg' => 'image/jpeg',
      'jpg' => 'image/jpeg',
      _ => 'image/jpeg',
    };
    final String payload = 'data:$mime;base64,${base64Encode(bytes)}';
    await _sendImagePayload(payload);
  }

  Future<void> _sendPickedImage(
    XFile file, {
    required String fallbackLabel,
  }) async {
    final String? payload = await _toDataImagePayload(file);
    if (payload == null) {
      final int localMessageId = _appendLocalOutgoingMessage(
        content: fallbackLabel,
      );
      await _sendContent(fallbackLabel, localMessageId: localMessageId);
      return;
    }
    await _sendImagePayload(payload);
  }

  Future<void> _sendImagePayload(String payload) async {
    final String content = payload.trim();
    if (content.isEmpty) return;
    final int localMessageId = _appendLocalOutgoingMessage(content: content);
    final String? url = await _uploadImageDataUrl(content);
    if (url == null || url.trim().isEmpty) {
      _markLocalOutgoingMessageFailed(localMessageId);
      return;
    }
    final String uploadedUrl = url.trim();
    _updateLocalOutgoingMessage(localMessageId, content: uploadedUrl);
    await _sendContent(uploadedUrl, localMessageId: localMessageId);
  }

  Future<String?> _uploadImageDataUrl(String dataUrl) async {
    try {
      final Uri url = Uri.parse('$_baseUrl/api/upload/image');
      final http.Response res = await http.post(
        url,
        headers: _headers(),
        body: jsonEncode({'data': dataUrl}),
      );
      if (res.statusCode == 401) {
        Get.offAllNamed('/login');
        return null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        String msg = '上传失败';
        try {
          final dynamic decoded = jsonDecode(res.body);
          if (decoded is Map &&
              (decoded['message'] ?? '').toString().trim().isNotEmpty) {
            msg = (decoded['message'] ?? '').toString().trim();
          }
        } catch (_) {}
        Get.snackbar('错误', msg);
        return null;
      }
      final dynamic decoded = jsonDecode(res.body);
      if (decoded is Map &&
          (decoded['url'] ?? '').toString().trim().isNotEmpty) {
        return (decoded['url'] ?? '').toString().trim();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _revokeMessage(int messageId) async {
    final Uri url = Uri.parse('$_baseUrl/api/messages/revoke-simple');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({'messageId': messageId}),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '撤回失败');
      return;
    }
    await _fetchMessages(forceFull: true);
  }

  Future<void> _deleteMessage(int messageId) async {
    final Uri url = Uri.parse('$_baseUrl/api/messages/delete-simple');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({'messageId': messageId}),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '删除失败');
      return;
    }
    await _fetchMessages(forceFull: true);
  }

  Future<void> _clearConversation() async {
    final int? fromId = _userId;
    if (fromId == null) return;

    final Uri url = Uri.parse('$_baseUrl/api/messages/clear');
    final http.Response res = await http.post(
      url,
      headers: _headers(),
      body: jsonEncode({'fromId': fromId, 'toId': widget.peerId}),
    );
    if (res.statusCode == 401) {
      Get.offAllNamed('/login');
      return;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      Get.snackbar('错误', '清空失败');
      return;
    }
    if (mounted) {
      setState(() {
        _messages = [];
        _maxMessageId = 0;
        _minMessageId = 0;
        _messageSignature = '';
        _reachedStart = true;
      });
    }
  }

  Future<void> _openCall() async {
    if (_calling) return;
    _calling = true;
    try {
      if (Get.currentRoute == '/call') return;
      if (kIsWeb) {
        Get.snackbar('提示', '请在手机 App 中使用语音通话功能');
        return;
      }
      if (_iBlocked) {
        Get.snackbar('提示', '你已拉黑该用户，无法发起通话');
        return;
      }
      if (_blockedMe) {
        Get.snackbar('提示', '对方已拉黑你，无法发起通话');
        return;
      }

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
                '请在系统设置中开启“麦克风”权限后再发起通话。\n路径：设置 → 隐私与安全性 → 麦克风',
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

      final int? fromId = _userId;
      if (fromId == null) return;

      try {
        await SignalService.instance.connect();
        final Map<String, String> info = SignalService.instance.sendCall(
          fromId,
          widget.peerId,
        );
        final String callId = info['callId'] ?? '';
        final String channelId = info['channelId'] ?? '';
        if (callId.isEmpty || channelId.isEmpty) return;
        if (Get.currentRoute == '/call') return;
        Get.toNamed(
          '/call',
          arguments: {
            'peerUsername': _peerDisplayName,
            'peerId': widget.peerId,
            'callId': callId,
            'channelId': channelId,
            'direction': 'outgoing',
          },
        );
      } catch (e) {
        Get.snackbar('错误', e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      _calling = false;
    }
  }

  void _insertEmoji(String emoji) {
    final TextEditingValue value = _inputController.value;
    final TextSelection selection = value.selection;

    final int start = selection.isValid ? selection.start : value.text.length;
    final int end = selection.isValid ? selection.end : value.text.length;

    final String newText = value.text.replaceRange(start, end, emoji);
    final int newOffset = start + emoji.length;
    _inputController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newOffset),
    );
    _inputFocusNode.requestFocus();
  }

  void _showEmojiPanel() {
    unawaited(
      _withPollingSuspended(() {
        return showModalBottomSheet<void>(
          context: context,
          backgroundColor: Theme.of(context).cardColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (context) {
            return DefaultTabController(
              length: 3,
              child: SizedBox(
                height: 300,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: '默认表情'),
                        Tab(text: '符号表情'),
                        Tab(text: '手势表情'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _EmojiGrid(
                            emojis: const [
                              '😀',
                              '😄',
                              '😆',
                              '😉',
                              '😍',
                              '😭',
                              '😡',
                              '🤔',
                            ],
                            onTap: (emoji) {
                              _insertEmoji(emoji);
                              setState(() {});
                              Navigator.of(context).pop();
                            },
                          ),
                          _EmojiGrid(
                            emojis: const [
                              '❤️',
                              '✨',
                              '⭐️',
                              '🔥',
                              '🎉',
                              '✅',
                              '❌',
                              '⚠️',
                            ],
                            onTap: (emoji) {
                              _insertEmoji(emoji);
                              setState(() {});
                              Navigator.of(context).pop();
                            },
                          ),
                          _EmojiGrid(
                            emojis: const [
                              '👍',
                              '👎',
                              '👏',
                              '🙏',
                              '🤝',
                              '✋',
                              '👌',
                              '🤙',
                            ],
                            onTap: (emoji) {
                              _insertEmoji(emoji);
                              setState(() {});
                              Navigator.of(context).pop();
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }

  void _showPlusMenu() {
    unawaited(
      _withPollingSuspended(() {
        return showModalBottomSheet<void>(
          context: context,
          backgroundColor: Theme.of(context).cardColor,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (context) {
            return SizedBox(
              height: 300,
              child: GridView.count(
                padding: const EdgeInsets.all(16),
                crossAxisCount: 4,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                children: [
                  _PlusMenuItem(
                    icon: Icons.photo_outlined,
                    label: '照片',
                    onTap: () {
                      Navigator.of(context).pop();
                      _pickFromGallery();
                    },
                  ),
                  _PlusMenuItem(
                    icon: Icons.photo_camera_outlined,
                    label: '拍摄',
                    onTap: () {
                      Navigator.of(context).pop();
                      _pickFromCamera();
                    },
                  ),
                  _PlusMenuItem(
                    icon: Icons.schedule,
                    label: '定时发送',
                    onTap: () {
                      Navigator.of(context).pop();
                      _openScheduleDialog();
                    },
                  ),
                  _PlusMenuItem(
                    icon: Icons.call_outlined,
                    label: '语音通话',
                    onTap: () {
                      Navigator.of(context).pop();
                      _openCall();
                    },
                  ),
                  _PlusMenuItem(
                    icon: Icons.delete_sweep_outlined,
                    label: '清空对话',
                    iconColor: const Color(0xFFC62828),
                    onTap: () async {
                      Navigator.of(context).pop();
                      final bool? ok = await _withPollingSuspended(() {
                        return showDialog<bool>(
                          context: this.context,
                          builder: (context) {
                            return AlertDialog(
                              title: const Text('清空对话'),
                              content: const Text('确认清空与该好友的所有消息？'),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(false),
                                  child: const Text('取消'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).pop(true),
                                  child: const Text('确认'),
                                ),
                              ],
                            );
                          },
                        );
                      });
                      if (ok == true) {
                        await _clearConversation();
                      }
                    },
                  ),
                ],
              ),
            );
          },
        );
      }),
    );
  }

  String? _extractFirstUrl(String text) {
    final RegExp re = RegExp(r'(https?:\/\/[^\s]+)', caseSensitive: false);
    final Match? m = re.firstMatch(text);
    return m?.group(0);
  }

  bool _isImageMessage(String content) {
    final String t = content.trim();
    if (t == '[图片]' || t == '[拍照]') return true;
    if (_isDataImagePayload(t)) return true;
    final Uri? uri = Uri.tryParse(t);
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final String lower = uri.path.toLowerCase();
      return lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.gif') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.heic');
    }
    return false;
  }

  String _imageLabel(String content) {
    final String t = content.trim();
    if (t == '[拍照]') return '拍照';
    return '图片';
  }

  bool _isDataImagePayload(String text) {
    final String t = text.trim();
    if (!t.startsWith('data:image/')) return false;
    return t.contains(';base64,');
  }

  Uint8List? _decodeDataImagePayload(String text) {
    final String t = text.trim();
    if (!_isDataImagePayload(t)) return null;
    final int idx = t.indexOf(';base64,');
    if (idx < 0) return null;
    final String b64 = t.substring(idx + ';base64,'.length);
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  Future<void> _copyTextToClipboard(String title, String text) async {
    final String t = text.trim();
    if (t.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: t));
    final String preview = t.length > 120 ? '${t.substring(0, 120)}…' : t;
    Get.snackbar(title, preview);
  }

  Future<String?> _toDataImagePayload(XFile file) async {
    try {
      final PreparedImageUploadData? prepared =
          await prepareMobileImageUploadData(file);
      if (prepared == null || prepared.bytes.isEmpty) return null;
      return prepared.dataUrl;
    } catch (_) {
      return null;
    }
  }

  bool _isSupportedWindowsDroppedImagePath(String path) {
    final String lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.heic');
  }

  Future<Map<String, dynamic>?> _toWindowsDroppedImagePayload(
    String path,
  ) async {
    try {
      final XFile file = XFile(path);
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return <String, dynamic>{
        'bytes': bytes,
        'payload': 'data:${_mimeFromUrl(path)};base64,${base64Encode(bytes)}',
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _sendDroppedImagePath(String path) async {
    final String filePath = path.trim();
    if (filePath.isEmpty) return;
    if (!_isSupportedWindowsDroppedImagePath(filePath)) {
      Get.snackbar('提示', '仅支持 jpg/jpeg/png/webp/gif/heic 图片');
      return;
    }
    final Map<String, dynamic>? prepared = await _toWindowsDroppedImagePayload(
      filePath,
    );
    final Uint8List? bytes = prepared?['bytes'] as Uint8List?;
    final String payload = (prepared?['payload'] ?? '').toString().trim();
    if (bytes == null || bytes.isEmpty || payload.isEmpty) {
      Get.snackbar('错误', '读取拖拽图片失败');
      return;
    }
    _showDroppedImagePreview(
      bytes: bytes,
      payload: payload,
      fileName: _fileNameFromPath(filePath),
    );
  }

  Future<void> _handleWindowsDropMethodCall(MethodCall call) async {
    if (!mounted || call.method != 'imageDropped') return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return;
    final String path = (call.arguments ?? '').toString().trim();
    if (path.isEmpty) return;
    await _sendDroppedImagePath(path);
  }

  void _showMessageActions(Map<String, dynamic> msg) {
    final int? id = int.tryParse(
      (msg['id'] ?? msg['message_id'] ?? msg['messageId'] ?? '').toString(),
    );
    if (id == null) return;
    final bool isRevoked =
        (msg['is_revoked'] ?? msg['isRevoked'] ?? 0).toString() == '1';
    final String content = isRevoked
        ? ''
        : (msg['content'] ?? '').toString().trim();
    final bool isDataImage = content.isNotEmpty && _isDataImagePayload(content);
    final String? url = isRevoked || content.isEmpty
        ? null
        : _extractFirstUrl(content);
    final Uri? uri = content.isNotEmpty ? Uri.tryParse(content) : null;
    final bool isNetworkImage =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    final bool canSaveImage = !isRevoked && (isDataImage || isNetworkImage);
    final bool canCopyText = !isRevoked && content.isNotEmpty && !isDataImage;
    final bool canCopyLink =
        !isRevoked &&
        ((url != null && url.trim().isNotEmpty) ||
            (isNetworkImage && content.isNotEmpty));

    Get.bottomSheet(
      SafeArea(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Get.back();
                    _setReplyFromMessage(msg);
                  },
                  child: const Text('引用'),
                ),
              ),
              if (canCopyText) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      Get.back();
                      await _copyTextToClipboard('已复制消息', content);
                    },
                    child: const Text('复制消息'),
                  ),
                ),
              ],
              if (canCopyLink) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      Get.back();
                      final String link =
                          (isNetworkImage ? content : (url ?? '')).trim();
                      await _copyTextToClipboard('已复制链接', link);
                    },
                    child: const Text('复制链接'),
                  ),
                ),
              ],
              if (canSaveImage) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () async {
                      Get.back();
                      Uint8List? bytes;
                      if (isDataImage) {
                        bytes = _imageBytesByMessageId[id];
                        bytes ??= await compute(
                          _decodeDataImagePayloadCompute,
                          content,
                        );
                      }
                      await _saveChatImageToGallery(
                        title: _imageLabel(content),
                        bytes: bytes,
                        url: isNetworkImage ? content : null,
                        mime: isDataImage
                            ? _mimeFromDataPayload(content)
                            : null,
                      );
                    },
                    child: const Text('保存图片'),
                  ),
                ),
              ],
              if (!isRevoked) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () async {
                      Get.back();
                      await _reportMessage(msg);
                    },
                    child: const Text('举报'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        Get.back();
                        await _revokeMessage(id);
                      },
                      child: const Text('撤回'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Get.back();
                        await _deleteMessage(id);
                      },
                      child: const Text('双向删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    CallState.isInCall.removeListener(_handleCallStateChanged);
    _stopMessagePolling();
    SignalService.instance.setActivePeer(null);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      _windowsChatDropChannel.setMethodCallHandler(null);
    }
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080C14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F131E),
        title: Text(
          _peerDisplayName,
          style: const TextStyle(
            color: Color(0xFFE8E8E8),
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            onPressed: _openCall,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'remark') _openRemarkDialog();
              if (value == 'clear') _clearConversation();
              if (value == 'toggleBlock') _toggleBlock();
            },
            itemBuilder: (context) {
              final List<PopupMenuEntry<String>> items = [];
              items.add(
                const PopupMenuItem<String>(
                  value: 'remark',
                  child: Text('修改备注'),
                ),
              );
              items.add(
                PopupMenuItem<String>(
                  value: 'toggleBlock',
                  child: Text(_iBlocked ? '解除拉黑' : '拉黑用户'),
                ),
              );
              if (_blockedMe) {
                items.add(
                  const PopupMenuItem<String>(
                    enabled: false,
                    value: '_blockedMe',
                    child: Text('对方已拉黑你'),
                  ),
                );
              }
              items.add(
                const PopupMenuItem<String>(
                  value: 'clear',
                  child: Text('清空对话'),
                ),
              );
              return items;
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Container(
                    color: const Color(0xFF080C14),
                    child: Builder(
                      builder: (BuildContext context) {
                        final List<Map<String, dynamic>> visibleMessages =
                            _visibleMessages;
                        return ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          itemCount: visibleMessages.length,
                          itemBuilder: (context, index) {
                            final Map<String, dynamic> msg =
                                visibleMessages[index];
                            final int? senderId = int.tryParse(
                              (msg['sender_id'] ?? msg['senderId'] ?? '')
                                  .toString(),
                            );
                            final bool isMe =
                                senderId != null && senderId == _userId;
                            final bool isRevoked =
                                (msg['is_revoked'] ?? msg['isRevoked'] ?? 0)
                                    .toString() ==
                                '1';
                            final String content = isRevoked
                                ? '已撤回'
                                : (msg['content'] ?? '').toString();
                            final bool isImage =
                                !isRevoked && _isImageMessage(content);
                            final Uri? contentUri = isImage
                                ? Uri.tryParse(content.trim())
                                : null;
                            final bool isNetworkImage =
                                contentUri != null &&
                                (contentUri.scheme == 'http' ||
                                    contentUri.scheme == 'https');
                            final int msgId =
                                int.tryParse(
                                  (msg['id'] ??
                                          msg['message_id'] ??
                                          msg['messageId'] ??
                                          '')
                                      .toString(),
                                ) ??
                                0;
                            final int replyToId =
                                int.tryParse(
                                  (msg['reply_to_id'] ?? msg['replyToId'] ?? '')
                                      .toString(),
                                ) ??
                                0;
                            final String replyPreview =
                                (msg['reply_preview'] ??
                                        msg['replyPreview'] ??
                                        '')
                                    .toString()
                                    .trim();
                            final String localStatus =
                                (msg['local_status'] ?? '').toString();
                            final String sendStatusText = isMe
                                ? _sendStatusText(localStatus)
                                : '';
                            final String timestampText = _formatBubbleTime(
                              (msg['timestamp'] ?? '').toString(),
                            );
                            Uint8List? imageBytes;
                            if (isImage && msgId > 0) {
                              imageBytes = _imageBytesByMessageId[msgId];
                            }
                            final String? url = (isRevoked || isImage)
                                ? null
                                : _extractFirstUrl(content);

                            final GlobalKey? k = msgId > 0
                                ? (_messageKeys[msgId] ??= GlobalKey())
                                : null;
                            return Container(
                              key: k,
                              child: _ChatBubble(
                                isMe: isMe,
                                text: content,
                                bubbleColor: isMe
                                    ? const Color(0xFFC62828)
                                    : const Color(0xFF1A1F2E),
                                textColor: const Color(0xFFE8E8E8),
                                isImage: isImage,
                                imageUrl: isImage && isNetworkImage
                                    ? content.trim()
                                    : null,
                                imageBytes: imageBytes,
                                imageLabel: isImage
                                    ? _imageLabel(content)
                                    : null,
                                replyPreview: replyPreview.isNotEmpty
                                    ? replyPreview
                                    : null,
                                timestampText: timestampText,
                                sendStatusText: sendStatusText,
                                sendStatusColor: _sendStatusColor(localStatus),
                                onTapReply: replyToId > 0
                                    ? () => _scrollToMessage(replyToId)
                                    : null,
                                isLink: url != null,
                                onTap: isImage
                                    ? () {
                                        if (!isNetworkImage &&
                                            imageBytes == null &&
                                            msgId > 0 &&
                                            _isDataImagePayload(content)) {
                                          _enqueueImageDecode(msgId, content);
                                          Get.snackbar('提示', '图片加载中');
                                          return;
                                        }
                                        _openImagePreview(
                                          title: _imageLabel(content),
                                          bytes: imageBytes,
                                          url: isNetworkImage
                                              ? content.trim()
                                              : null,
                                        );
                                      }
                                    : url == null
                                    ? (isRevoked
                                          ? null
                                          : () async {
                                              await _copyTextToClipboard(
                                                '已复制消息',
                                                content,
                                              );
                                            })
                                    : () async {
                                        await _copyTextToClipboard(
                                          '已复制链接',
                                          url,
                                        );
                                      },
                                onLongPress: msgId > 0
                                    ? () => _showMessageActions(msg)
                                    : () {},
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),
                _buildComposer(),
              ],
            ),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: const BoxDecoration(
          color: Color(0xFF0F131E),
          border: Border(top: BorderSide(color: Color(0xFF1A1F2E), width: 1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingDroppedImagePayload != null &&
                _pendingDroppedImagePayload!.trim().isNotEmpty)
              _buildDroppedImagePreviewCard(),
            if (_replyPreview != null && _replyPreview!.trim().isNotEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF141825),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  border: Border.all(color: const Color(0xFF1A1F2E), width: 1),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _replyPreview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xFFB0B0B0),
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkResponse(
                      onTap: _clearReply,
                      radius: 18,
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Color(0xFF8B8B8B),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  color: const Color(0xFF8B8B8B),
                  onPressed: _showEmojiPanel,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: 40,
                      maxHeight: 130,
                    ),
                    child: Container(
                      padding: const EdgeInsets.only(left: 6, right: 10),
                      decoration: const BoxDecoration(
                        color: Color(0xFF141825),
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            color: const Color(0xFF8B8B8B),
                            onPressed: _showPlusMenu,
                          ),
                          Expanded(
                            child: Focus(
                              onKeyEvent: _handleWindowsEnterToSend,
                              child: TextField(
                                controller: _inputController,
                                focusNode: _inputFocusNode,
                                keyboardType: TextInputType.multiline,
                                textInputAction: TextInputAction.newline,
                                minLines: 1,
                                maxLines: 5,
                                style: const TextStyle(
                                  color: Color(0xFFE8E8E8),
                                  fontSize: 14,
                                ),
                                decoration: const InputDecoration(
                                  hintText: '输入消息',
                                  hintStyle: TextStyle(
                                    color: Color(0xFF555555),
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _send,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFB8960C),
                    textStyle: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: const Text('发送'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  final List<String> emojis;
  final ValueChanged<String> onTap;

  const _EmojiGrid({required this.emojis, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: emojis.length,
      itemBuilder: (context, index) {
        final String emoji = emojis[index];
        return InkResponse(
          onTap: () => onTap(emoji),
          radius: 22,
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 20)),
          ),
        );
      },
    );
  }
}

class _PlusMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  const _PlusMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 40,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: const BorderRadius.all(Radius.circular(14)),
            ),
            child: Icon(icon, color: iconColor ?? Colors.white),
          ),
          const SizedBox(height: 8),
          Text(label),
        ],
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  final bool isMe;
  final String text;
  final Color bubbleColor;
  final Color textColor;
  final bool isImage;
  final String? imageUrl;
  final Uint8List? imageBytes;
  final String? imageLabel;
  final String? replyPreview;
  final String timestampText;
  final String sendStatusText;
  final Color sendStatusColor;
  final VoidCallback? onTapReply;
  final bool isLink;
  final VoidCallback? onTap;
  final VoidCallback onLongPress;

  const _ChatBubble({
    required this.isMe,
    required this.text,
    required this.bubbleColor,
    required this.textColor,
    required this.isImage,
    required this.imageUrl,
    required this.imageBytes,
    required this.imageLabel,
    required this.replyPreview,
    required this.timestampText,
    required this.sendStatusText,
    required this.sendStatusColor,
    required this.onTapReply,
    required this.isLink,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 14),
      child: Row(
        mainAxisAlignment: isMe
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: bubbleColor,
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(isMe ? 14 : 4),
                        topRight: const Radius.circular(14),
                        bottomLeft: const Radius.circular(14),
                        bottomRight: Radius.circular(isMe ? 4 : 14),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (replyPreview != null &&
                            replyPreview!.trim().isNotEmpty)
                          GestureDetector(
                            onTap: onTapReply,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(10),
                                ),
                              ),
                              child: Text(
                                replyPreview!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFFD0D0D0),
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        isImage
                            ? _ImageBubble(
                                url: imageUrl,
                                bytes: imageBytes,
                                label: imageLabel ?? '图片',
                                textColor: textColor,
                              )
                            : Text(
                                text,
                                style: TextStyle(
                                  color: isLink
                                      ? const Color(0xFFB8960C)
                                      : textColor,
                                  decoration: isLink
                                      ? TextDecoration.underline
                                      : TextDecoration.none,
                                  decorationColor: isLink
                                      ? const Color(0xFFB8960C)
                                      : Colors.transparent,
                                  fontSize: 14,
                                ),
                              ),
                      ],
                    ),
                  ),
                ),
                if (timestampText.isNotEmpty || sendStatusText.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 2, right: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (timestampText.isNotEmpty)
                          Text(
                            timestampText,
                            style: const TextStyle(
                              color: Color(0xFF6F7785),
                              fontSize: 10,
                              height: 1.1,
                            ),
                          ),
                        if (timestampText.isNotEmpty &&
                            sendStatusText.isNotEmpty)
                          const SizedBox(width: 6),
                        if (sendStatusText.isNotEmpty)
                          Text(
                            sendStatusText,
                            style: TextStyle(
                              color: sendStatusColor,
                              fontSize: 9,
                              height: 1.1,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageBubble extends StatelessWidget {
  final String? url;
  final Uint8List? bytes;
  final String label;
  final Color textColor;

  const _ImageBubble({
    required this.url,
    required this.bytes,
    required this.label,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    final Widget fallback = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.image_outlined, size: 18, color: Colors.white),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: textColor, fontSize: 14)),
      ],
    );

    final Widget image = bytes != null
        ? Image.memory(
            bytes!,
            gaplessPlayback: true,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => fallback,
          )
        : url != null
        ? Image.network(
            url!,
            gaplessPlayback: true,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) => fallback,
          )
        : fallback;

    if (url == null && bytes == null) return fallback;

    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220, maxHeight: 260),
        child: image,
      ),
    );
  }
}

Uint8List? _decodeDataImagePayloadCompute(String text) {
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
