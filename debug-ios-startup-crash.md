# Debug Session: ios-startup-crash
- **Status**: [OPEN]
- **Issue**: iPhone installed app flashes and exits immediately on foreground launch.
- **Debug Server**: N/A (collecting native/runtime evidence first)
- **Log File**: N/A

## Reproduction Steps
1. Install `com.fenghuo.mixin` to iPhone `嘎嘎`.
2. Tap `烽火密信` on the device home screen.
3. Observe app flashes briefly and exits.

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | iOS startup crash is caused by a missing/invalid native runtime dependency or plugin registration issue | High | Low | Pending |
| B | App exits during Flutter bootstrap because a foreground service initializes with an uncaught exception on iOS | High | Low | Pending |
| C | A recently added dependency/resource causes iOS launch-time failure before first frame | Medium | Low | Pending |
| D | Code signing / entitlements mismatch causes launch to be terminated by the system after install | Low | Medium | Pending |

## Log Evidence
- 2026-07-14 00:36-00:40 抓取多份真机 `Runner-*.ips`，一致出现：
  - `EXC_BAD_ACCESS / SIGSEGV`
  - `-[VSyncClient initWithTaskRunner:callback:]`
  - `-[FlutterViewController createTouchRateCorrectionVSyncClientIfNeeded]`
- 2026-07-14 00:45 核查旧安装链路产物 `build/ios/iphoneos/Runner.app`：
  - `build/ios/iphoneos/Runner.app/Frameworks/Flutter.framework/Info.plist` 中 `BuildMode = debug`
  - 包内存在 `Runner.debug.dylib`
  - `App.framework/flutter_assets` 中存在 `kernel_blob.bin`
- 2026-07-14 00:47 执行 `flutter build ios --release` 重新生成 iOS 包后，复核新产物：
  - `BuildMode = release`
  - 不再包含 `Runner.debug.dylib`
  - 不再包含 `kernel_blob.bin`
- 2026-07-14 00:48-00:50 使用 `devicectl` 卸载旧包并安装新 release 包：
  - `bundleID: com.fenghuo.mixin`
  - 安装成功
- 2026-07-14 00:50 使用 `devicectl device process launch --console` 启动：
  - 应用成功拉起并输出 Agora 初始化日志
  - 未出现秒退
- 2026-07-14 00:50 再次检查 `systemCrashLogs`：
  - 未生成新的 `Runner-2026-07-14-005*.ips`

## Verification Conclusion
- 已确认此前“一闪退”的主要原因不是业务逻辑本身，而是安装到了调试态 iOS 产物；该产物命中了 iOS 18.5 上 Flutter `VSyncClient / createTouchRateCorrectionVSyncClientIfNeeded` 启动崩溃。
- 重新生成并安装真正的 release 包后，命令行侧已完成一次成功启动且未产生新的 Runner 崩溃日志。
- 当前状态：等待用户在手机桌面手动点击 `烽火密信` 做最终确认。
