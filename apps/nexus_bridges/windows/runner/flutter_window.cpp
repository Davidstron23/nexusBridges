#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

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
  result->NotImplemented();
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
