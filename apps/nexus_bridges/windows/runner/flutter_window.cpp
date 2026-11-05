#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <cstdio>
#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr UINT_PTR kTrayRetryTimer = 1;
constexpr UINT kTrayRetryInterval = 2000;
constexpr int kTrayMaxRetries = 5;
constexpr UINT kMenuOpen = 1;
constexpr UINT kMenuExit = 2;

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableMap* arguments, const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto found = arguments->find(flutter::EncodableValue(std::string(key)));
  return found == arguments->end() ? nullptr : &found->second;
}

bool ReadBool(const flutter::EncodableMap* arguments, const char* key,
              bool* value) {
  const auto* found = FindArgument(arguments, key);
  if (found == nullptr || std::get_if<bool>(found) == nullptr) {
    return false;
  }
  *value = std::get<bool>(*found);
  return true;
}

bool ReadText(const flutter::EncodableMap* arguments, const char* key,
              std::wstring* value) {
  const auto* found = FindArgument(arguments, key);
  if (found == nullptr || std::get_if<std::string>(found) == nullptr) {
    return false;
  }
  *value = Utf16FromUtf8(std::get<std::string>(*found));
  return true;
}

}

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_ = ::RegisterWindowMessageW(L"TaskbarCreated");

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "nexus_bridges/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleWindowCall(call, std::move(result)); });

  drop_view_ = flutter_controller_->view()->GetNativeWindow();
  drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "nexus_bridges/drop",
          &flutter::StandardMethodCodec::GetInstance());
  drop_target_ = new DropTarget(drop_view_, drop_channel_.get());
  const HRESULT drop_result = ::RegisterDragDrop(drop_view_, drop_target_);
  if (SUCCEEDED(drop_result)) {
    drop_registered_ = true;
  } else {
    std::fprintf(stderr, "RegisterDragDrop failed: 0x%08lx\n",
                 static_cast<unsigned long>(drop_result));
    drop_target_->Release();
    drop_target_ = nullptr;
  }

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
  StopTrayRetry();
  tray_.Remove();
  attached_ = false;

  if (drop_registered_) {
    ::RevokeDragDrop(drop_view_);
    drop_registered_ = false;
  }
  if (drop_target_) {
    drop_target_->Detach();
    drop_target_->Release();
    drop_target_ = nullptr;
  }
  drop_channel_ = nullptr;
  window_channel_ = nullptr;

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "setDarkTitleBar") {
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("bad_arguments");
      return;
    }
    const auto dark = arguments->find(flutter::EncodableValue("dark"));
    if (dark == arguments->end() ||
        std::get_if<bool>(&dark->second) == nullptr) {
      result->Error("bad_arguments");
      return;
    }
    SetDarkTitleBar(std::get<bool>(dark->second));
    result->Success();
    return;
  }
  if (HandleShellCall(call, result)) {
    return;
  }
  result->NotImplemented();
}

bool FlutterWindow::HandleShellCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result) {
  const std::string& method = call.method_name();
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  HWND hwnd = GetHandle();
  if (method == "attach") {
    attached_ = true;
    result->Success(flutter::EncodableValue(true));
    return true;
  }
  if (method == "setTray") {
    bool enabled = false;
    std::wstring tooltip;
    std::wstring open;
    std::wstring exit;
    if (!ReadBool(arguments, "enabled", &enabled) ||
        !ReadText(arguments, "tooltip", &tooltip) ||
        !ReadText(arguments, "open", &open) ||
        !ReadText(arguments, "exit", &exit)) {
      result->Error("bad_arguments");
      return true;
    }
    tray_enabled_ = enabled;
    tray_tooltip_ = tooltip;
    tray_open_ = open;
    tray_exit_ = exit;
    if (!enabled) {
      StopTrayRetry();
      tray_.Remove();
    } else if (tray_.visible()) {
      tray_.SetTooltip(tray_tooltip_);
    } else {
      StopTrayRetry();
      if (!AddTrayIcon()) {
        StartTrayRetry();
      }
    }
    tray_visible_reported_ = tray_.visible();
    result->Success(flutter::EncodableValue(tray_.visible()));
    return true;
  }
  if (method == "showTrayHint") {
    std::wstring title;
    std::wstring body;
    if (!ReadText(arguments, "title", &title) ||
        !ReadText(arguments, "body", &body)) {
      result->Error("bad_arguments");
      return true;
    }
    result->Success(flutter::EncodableValue(tray_.ShowBalloon(title, body)));
    return true;
  }
  if (method == "hide") {
    if (hwnd != nullptr) {
      ::ShowWindow(hwnd, SW_HIDE);
    }
    result->Success();
    return true;
  }
  if (method == "show") {
    ShowAndActivate();
    result->Success();
    return true;
  }
  if (method == "minimize") {
    if (hwnd != nullptr) {
      ::ShowWindow(hwnd, SW_MINIMIZE);
    }
    result->Success();
    return true;
  }
  if (method == "attention") {
    flutter::EncodableMap reply;
    reply[flutter::EncodableValue(std::string("foreground"))] =
        flutter::EncodableValue(BringForAttention());
    result->Success(flutter::EncodableValue(reply));
    return true;
  }
  if (method == "quit") {
    attached_ = false;
    if (hwnd != nullptr) {
      ::PostMessage(hwnd, kQuitMessage, 0, 0);
    }
    result->Success();
    return true;
  }
  return false;
}

bool FlutterWindow::AddTrayIcon() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  return tray_.Add(hwnd, tray_tooltip_);
}

void FlutterWindow::StartTrayRetry() {
  tray_retries_ = 0;
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::SetTimer(hwnd, kTrayRetryTimer, kTrayRetryInterval, nullptr);
  }
}

void FlutterWindow::StopTrayRetry() {
  HWND hwnd = GetHandle();
  if (hwnd != nullptr) {
    ::KillTimer(hwnd, kTrayRetryTimer);
  }
}

void FlutterWindow::SendEvent(const char* name) {
  if (window_channel_) {
    window_channel_->InvokeMethod(name, nullptr);
  }
}

void FlutterWindow::ReportTrayVisibility() {
  const bool visible = tray_.visible();
  if (visible == tray_visible_reported_ || !window_channel_) {
    return;
  }
  tray_visible_reported_ = visible;
  auto arguments = std::make_unique<flutter::EncodableValue>(
      flutter::EncodableMap{{flutter::EncodableValue(std::string("visible")),
                             flutter::EncodableValue(visible)}});
  window_channel_->InvokeMethod("trayVisibility", std::move(arguments));
}

void FlutterWindow::ShowAndActivate() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  }
  ::SetForegroundWindow(hwnd);
}

bool FlutterWindow::BringForAttention() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  if (::IsWindowVisible(hwnd) && !::IsIconic(hwnd) &&
      ::GetForegroundWindow() == hwnd) {
    return true;
  }
  if (!::IsWindowVisible(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOWNA);
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_SHOWNOACTIVATE);
  }
  const bool foreground = ::SetForegroundWindow(hwnd) != FALSE;
  if (!foreground) {
    FLASHWINFO flash = {};
    flash.cbSize = sizeof(FLASHWINFO);
    flash.hwnd = hwnd;
    flash.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
    ::FlashWindowEx(&flash);
  }
  return foreground;
}

void FlutterWindow::ShowTrayMenu(int x, int y) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kMenuOpen, tray_open_.c_str());
  ::AppendMenuW(menu, MF_STRING, kMenuExit, tray_exit_.c_str());
  ::SetForegroundWindow(hwnd);
  const UINT command = static_cast<UINT>(::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, x, y, hwnd,
      nullptr));
  ::PostMessage(hwnd, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  if (command == kMenuOpen) {
    ShowAndActivate();
  } else if (command == kMenuExit) {
    SendEvent("exitRequested");
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    if (tray_enabled_) {
      StopTrayRetry();
      if (!AddTrayIcon()) {
        StartTrayRetry();
      }
      ReportTrayVisibility();
    }
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      if (attached_ && window_channel_) {
        SendEvent("closeRequested");
        return 0;
      }
      break;

    case kQuitMessage:
      tray_.Remove();
      ::DestroyWindow(hwnd);
      return 0;

    case kTrayMessage:
      switch (LOWORD(lparam)) {
        case NIN_SELECT:
        case NIN_KEYSELECT:
        case WM_LBUTTONDBLCLK:
          ShowAndActivate();
          break;
        case WM_CONTEXTMENU:
          ShowTrayMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
          break;
      }
      return 0;

    case WM_TIMER:
      if (wparam == kTrayRetryTimer) {
        ++tray_retries_;
        if (!tray_enabled_ || AddTrayIcon() ||
            tray_retries_ >= kTrayMaxRetries) {
          StopTrayRetry();
        }
        ReportTrayVisibility();
        return 0;
      }
      break;

    case WM_DPICHANGED:
    case WM_SETTINGCHANGE:
      tray_.RefreshIcon();
      break;

    case WM_QUERYENDSESSION:
      if ((lparam & ENDSESSION_CLOSEAPP) != 0) {
        return TRUE;
      }
      break;

    case WM_ENDSESSION:
      if (wparam != 0) {
        if ((lparam & ENDSESSION_CLOSEAPP) != 0) {
          SendEvent("exitRequested");
          return 0;
        }
        tray_.Remove();
      }
      break;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
