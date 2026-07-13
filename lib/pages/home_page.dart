import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'contacts_page.dart';
import 'game_page.dart';
import 'login_page.dart';
import 'messages_page.dart';
import 'profile_page.dart';
import '../services/signal_service.dart';

class HomeController extends GetxController {
  final RxInt currentIndex = 0.obs;
  final RxInt unreadCount = 0.obs;
  final RxInt friendRequestCount = 0.obs;

  void changeIndex(int index) {
    currentIndex.value = index;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const String _baseUrl = 'https://fenghuomixin.online';

  late final HomeController controller;

  @override
  void initState() {
    super.initState();
    controller = Get.put(HomeController());
    if (!Get.isRegistered<RxInt>(tag: 'homeTabIndex')) {
      Get.put<RxInt>(controller.currentIndex, tag: 'homeTabIndex');
    }
    if (!Get.isRegistered<RxInt>(tag: 'homeUnreadCount')) {
      Get.put<RxInt>(controller.unreadCount, tag: 'homeUnreadCount');
    }
    if (!Get.isRegistered<RxInt>(tag: 'homeFriendRequestCount')) {
      Get.put<RxInt>(controller.friendRequestCount, tag: 'homeFriendRequestCount');
    }
    controller.unreadCount.value = SignalService.instance.totalUnread();
    controller.friendRequestCount.value = SignalService.instance.friendRequestCount();
    _initUnreadPolling();
  }

  Future<void> _initUnreadPolling() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? token = prefs.getString('token');
    final int? userId = (int.tryParse((prefs.get('userId') ?? '').toString()));

    if (token == null || token.isEmpty || userId == null) {
      Get.offAll(() => const LoginPage());
      return;
    }

    await SignalService.instance.connect();
    await _syncConversationsFromServer(token: token, userId: userId);
  }

  Future<void> _syncConversationsFromServer({
    required String token,
    required int userId,
  }) async {
    try {
      final Uri url = Uri.parse('$_baseUrl/api/conversations')
          .replace(queryParameters: {'userId': userId.toString()});
      final http.Response res = await http.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );
      if (res.statusCode == 401) {
        Get.offAll(() => const LoginPage());
        return;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) return;

      final dynamic decoded = jsonDecode(res.body);
      if (decoded is! Map<String, dynamic>) return;
      final List<dynamic> list =
          (decoded['conversations'] as List<dynamic>? ?? const []);

      final Map<int, int> snapshot = <int, int>{};
      for (final item in list) {
        if (item is! Map) continue;
        final Map<String, dynamic> m = Map<String, dynamic>.from(item);
        final int? peerId = int.tryParse((m['id'] ?? '').toString());
        if (peerId == null) continue;
        final int unread = int.tryParse((m['unreadCount'] ?? 0).toString()) ?? 0;
        snapshot[peerId] = unread;
        SignalService.instance.updateConversationSnapshot(
          peerId: peerId,
          lastMessage: (m['lastMessage'] ?? '').toString(),
          lastTime: (m['lastTime'] ?? '').toString(),
          unreadCount: unread,
        );
      }
      SignalService.instance.setUnreadSnapshot(snapshot);
    } catch (_) {}
  }

  Widget _messageTabIcon(int unreadCount) {
    final String text = unreadCount > 99 ? '99+' : unreadCount.toString();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.chat_bubble_outline_rounded),
        if (unreadCount > 0)
          Positioned(
            right: -8,
            top: -6,
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
                text,
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
    );
  }

  Widget _contactsTabIcon(int requestCount) {
    final String text = requestCount > 99 ? '99+' : requestCount.toString();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.people_outline_rounded),
        if (requestCount > 0)
          Positioned(
            right: -8,
            top: -6,
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
                text,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Obx(
      () => Scaffold(
        backgroundColor: const Color(0xFF080C14),
        body: IndexedStack(
          index: controller.currentIndex.value,
          children: const [
            MessagesPage(),
            ContactsPage(),
            GamePage(),
            ProfilePage(),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0F131E),
            border: Border(top: BorderSide(color: Color(0xFF1A1F2E), width: 1)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 60,
              child: BottomNavigationBar(
                currentIndex: controller.currentIndex.value,
                onTap: (index) {
                  controller.changeIndex(index);
                },
                type: BottomNavigationBarType.fixed,
                backgroundColor: const Color(0xFF0F131E),
                selectedItemColor: const Color(0xFFB8960C),
                unselectedItemColor: const Color(0xFF555555),
                selectedLabelStyle: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                ),
                items: [
                  BottomNavigationBarItem(
                    icon: _messageTabIcon(controller.unreadCount.value),
                    label: '消息',
                  ),
                  BottomNavigationBarItem(
                    icon: _contactsTabIcon(controller.friendRequestCount.value),
                    label: '通讯录',
                  ),
                  const BottomNavigationBarItem(
                    icon: Icon(Icons.games_rounded),
                    label: '游戏',
                  ),
                  const BottomNavigationBarItem(
                    icon: Icon(Icons.person_outline_rounded),
                    label: '我的',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
