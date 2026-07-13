#include "flutter_window.h"

#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

bool IsWindowForeground(HWND hwnd) {
  return hwnd != nullptr && ::GetForegroundWindow() == hwnd;
}

void FlashTaskbarUntilForeground(HWND hwnd) {
  FLASHWINFO info = {};
  info.cbSize = sizeof(FLASHWINFO);
  info.hwnd = hwnd;
  info.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
  info.uCount = 0;
  info.dwTimeout = 0;
  ::FlashWindowEx(&info);
}

void StopTaskbarFlash(HWND hwnd) {
  FLASHWINFO info = {};
  info.cbSize = sizeof(FLASHWINFO);
  info.hwnd = hwnd;
  info.dwFlags = FLASHW_STOP;
  info.uCount = 0;
  info.dwTimeout = 0;
  ::FlashWindowEx(&info);
}

std::string Utf8FromWide(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int size_needed = ::WideCharToMultiByte(
      CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()), nullptr, 0,
      nullptr, nullptr);
  if (size_needed <= 0) {
    return std::string();
  }
  std::string result(size_needed, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                        static_cast<int>(value.size()), result.data(),
                        size_needed, nullptr, nullptr);
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  windows_system_sound_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "fenghuo/windows_system_sound",
          &flutter::StandardMethodCodec::GetInstance());
  windows_system_sound_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "playMessageBeep") {
          ::MessageBeep(MB_ICONASTERISK);
          result->Success();
          return;
        }
        if (call.method_name() == "flashWindow") {
          const HWND hwnd = GetHandle();
          if (!is_taskbar_flashing_ && !IsWindowForeground(hwnd)) {
            FlashTaskbarUntilForeground(hwnd);
            is_taskbar_flashing_ = true;
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  windows_chat_drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "fenghuo/windows_chat_drop",
          &flutter::StandardMethodCodec::GetInstance());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ::DragAcceptFiles(GetHandle(), TRUE);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  StopTaskbarFlash(GetHandle());
  is_taskbar_flashing_ = false;
  ::DragAcceptFiles(GetHandle(), FALSE);
  windows_chat_drop_channel_.reset();
  windows_system_sound_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_ACTIVATE:
      if (LOWORD(wparam) != WA_INACTIVE) {
        StopTaskbarFlash(hwnd);
        is_taskbar_flashing_ = false;
      }
      break;
    case WM_DROPFILES: {
      if (windows_chat_drop_channel_ == nullptr) {
        break;
      }
      HDROP drop_handle = reinterpret_cast<HDROP>(wparam);
      const UINT file_count = ::DragQueryFileW(drop_handle, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < file_count; ++i) {
        const UINT path_length = ::DragQueryFileW(drop_handle, i, nullptr, 0);
        if (path_length == 0) {
          continue;
        }
        std::wstring wide_path(path_length + 1, L'\0');
        ::DragQueryFileW(drop_handle, i, wide_path.data(), path_length + 1);
        wide_path.resize(path_length);
        const std::string utf8_path = Utf8FromWide(wide_path);
        if (utf8_path.empty()) {
          continue;
        }
        windows_chat_drop_channel_->InvokeMethod(
            "imageDropped",
            std::make_unique<flutter::EncodableValue>(utf8_path));
      }
      ::DragFinish(drop_handle);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
