#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <string>

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kQuitMessage = WM_APP + 2;

class TrayIcon {
 public:
  bool Add(HWND window, const std::wstring& tooltip);
  void SetTooltip(const std::wstring& tooltip);
  bool ShowBalloon(const std::wstring& title, const std::wstring& body);
  void RefreshIcon();
  void Remove();
  bool visible() const;

 private:
  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  bool visible_ = false;
};

#endif
