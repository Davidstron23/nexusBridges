#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <memory>
#include <string>

#include "drop_target.h"
#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  void HandleWindowCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool HandleShellCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>& result);

  bool AddTrayIcon();
  void StartTrayRetry();
  void StopTrayRetry();
  void ReportTrayVisibility();
  void ShowTrayMenu(int x, int y);
  void ShowAndActivate();
  bool BringForAttention();
  void SendEvent(const char* name);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> drop_channel_;
  DropTarget* drop_target_ = nullptr;
  HWND drop_view_ = nullptr;
  bool drop_registered_ = false;

  TrayIcon tray_;
  bool attached_ = false;
  bool tray_enabled_ = false;
  bool tray_visible_reported_ = false;
  int tray_retries_ = 0;
  UINT taskbar_created_ = 0;
  std::wstring tray_tooltip_;
  std::wstring tray_open_;
  std::wstring tray_exit_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
