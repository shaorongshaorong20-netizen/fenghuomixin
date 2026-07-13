import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'pages/call_page.dart';
import 'pages/home_page.dart';
import 'pages/chat_page.dart';
import 'pages/login_page.dart';
import 'pages/splash_page.dart';
import 'services/call_service.dart';
import 'services/signal_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() async {
      try {
        await SignalService.instance.initLocalNotifications();
      } catch (_) {}
      try {
        await SignalService.instance.connect();
      } catch (_) {}
    });
    _sub = SignalService.instance.listen().listen((event) {
      if (event.type != 'call') return;
      final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
      if (state != null && state != AppLifecycleState.resumed) return;
      final dynamic rawFromId =
          event.data['fromId'] ?? event.data['fromUserId'] ?? event.data['from_id'];
      final int? fromId = int.tryParse((rawFromId ?? '').toString());
      final String callId =
          (event.data['callId'] ?? event.data['call_id'] ?? event.data['id'] ?? '').toString();
      final String channelId = (event.data['channelId'] ??
              event.data['channel'] ??
              event.data['channelName'] ??
              event.data['roomId'] ??
              '')
          .toString();
      if (fromId == null || callId.isEmpty || channelId.isEmpty) return;
      if (Get.currentRoute == '/call') return;
      Get.toNamed(
        '/call',
        arguments: {
          'peerId': fromId,
          'peerUsername': SignalService.instance.displayNameForPeer(fromId, fallback: fromId.toString()),
          'callId': callId,
          'channelId': channelId,
          'direction': 'incoming',
        },
      );
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'Flutter Demo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      builder: (context, child) {
        final Widget safeChild = child ?? const SizedBox.shrink();
        return Obx(() {
          final Map<String, dynamic>? overlay = SignalService.instance.callOverlay.value;
          if (overlay == null) return safeChild;
          final bool showOverlay =
              CallService.instance.isMinimized() && Get.currentRoute != '/call';
          if (!showOverlay) return safeChild;

          final int? peerId = int.tryParse((overlay['peerId'] ?? '').toString());
          final String peerName = (overlay['peerName'] ?? '').toString().trim();
          final String callId = (overlay['callId'] ?? '').toString();
          final String channelId = (overlay['channelId'] ?? '').toString();
          final int? startedAtMs = int.tryParse((overlay['startedAtMs'] ?? '').toString());
          if (peerId == null || callId.isEmpty || channelId.isEmpty) return safeChild;

          final double bottom =
              76 + MediaQuery.of(context).viewPadding.bottom.toDouble();

          return Stack(
            children: [
              safeChild,
              Positioned(
                left: 14,
                right: 14,
                bottom: bottom,
                child: Material(
                  color: const Color(0xFF121826),
                  borderRadius: const BorderRadius.all(Radius.circular(14)),
                  child: InkWell(
                    borderRadius: const BorderRadius.all(Radius.circular(14)),
                    onTap: () {
                      CallService.instance.setMinimized(false);
                      SignalService.instance.clearCallOverlay();
                      Get.toNamed(
                        '/call',
                        arguments: {
                          'peerId': peerId,
                          'peerUsername': peerName.isNotEmpty ? peerName : peerId.toString(),
                          'callId': callId,
                          'channelId': channelId,
                          'direction': 'inCall',
                          'startedAtMs': startedAtMs,
                        },
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.call_rounded, color: Color(0xFFB8960C), size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '通话中：${peerName.isNotEmpty ? peerName : peerId.toString()}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: () {
                              SignalService.instance.clearCallOverlay();
                              CallService.instance.setMinimized(false);
                              try {
                                SignalService.instance.sendHangup(callId, toId: peerId);
                              } catch (_) {}
                              CallService.instance.leaveChannel();
                            },
                            icon: const Icon(Icons.call_end_rounded, color: Color(0xFFC62828)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        });
      },
      home: const SplashPage(),
      getPages: [
        GetPage(name: '/', page: () => const HomePage()),
        GetPage(name: '/login', page: () => const LoginPage()),
        GetPage(name: '/chat', page: () => ChatPage.fromRoute()),
        GetPage(name: '/call', page: () => CallPage.fromRoute()),
      ],
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;

  void _incrementCounter() {
    setState(() {
      // This call to setState tells the Flutter framework that something has
      // changed in this State, which causes it to rerun the build method below
      // so that the display can reflect the updated values. If we changed
      // _counter without calling setState(), then the build method would not be
      // called again, and so nothing would appear to happen.
      _counter++;
    });
  }

  @override
  Widget build(BuildContext context) {
    // This method is rerun every time setState is called, for instance as done
    // by the _incrementCounter method above.
    //
    // The Flutter framework has been optimized to make rerunning build methods
    // fast, so that you can just rebuild anything that needs updating rather
    // than having to individually change instances of widgets.
    return Scaffold(
      appBar: AppBar(
        // TRY THIS: Try changing the color here to a specific color (to
        // Colors.amber, perhaps?) and trigger a hot reload to see the AppBar
        // change color while the other colors stay the same.
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          // Column is also a layout widget. It takes a list of children and
          // arranges them vertically. By default, it sizes itself to fit its
          // children horizontally, and tries to be as tall as its parent.
          //
          // Column has various properties to control how it sizes itself and
          // how it positions its children. Here we use mainAxisAlignment to
          // center the children vertically; the main axis here is the vertical
          // axis because Columns are vertical (the cross axis would be
          // horizontal).
          //
          // TRY THIS: Invoke "debug painting" (choose the "Toggle Debug Paint"
          // action in the IDE, or press "p" in the console), to see the
          // wireframe for each widget.
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
