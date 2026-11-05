#include "tray_icon.h"

#include <shellapi.h>

#include "resource.h"

namespace {

constexpr UINT kIconId = 1;

NOTIFYICONDATAW BaseData(HWND window) {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(NOTIFYICONDATAW);
  data.hWnd = window;
  data.uID = kIconId;
  return data;
}

template <size_t N>
void CopyText(wchar_t (&target)[N], const std::wstring& text) {
  wcsncpy_s(target, N, text.c_str(), _TRUNCATE);
}

HICON LoadTrayIcon() {
  const UINT dpi = GetDpiForSystem();
  return static_cast<HICON>(
      LoadImageW(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON),
                 IMAGE_ICON, GetSystemMetricsForDpi(SM_CXSMICON, dpi),
                 GetSystemMetricsForDpi(SM_CYSMICON, dpi), LR_DEFAULTCOLOR));
}

}

bool TrayIcon::Add(HWND window, const std::wstring& tooltip) {
  window_ = window;
  HICON icon = LoadTrayIcon();
  if (icon == nullptr) {
    visible_ = false;
    return false;
  }
  NOTIFYICONDATAW data = BaseData(window);
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = icon;
  CopyText(data.szTip, tooltip);
  if (!Shell_NotifyIconW(NIM_ADD, &data) &&
      !Shell_NotifyIconW(NIM_MODIFY, &data)) {
    DestroyIcon(icon);
    visible_ = false;
    return false;
  }
  data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data);
  if (icon_ != nullptr) {
    DestroyIcon(icon_);
  }
  icon_ = icon;
  visible_ = true;
  return true;
}

void TrayIcon::SetTooltip(const std::wstring& tooltip) {
  if (!visible_) {
    return;
  }
  NOTIFYICONDATAW data = BaseData(window_);
  data.uFlags = NIF_TIP | NIF_SHOWTIP;
  CopyText(data.szTip, tooltip);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

bool TrayIcon::ShowBalloon(const std::wstring& title,
                           const std::wstring& body) {
  if (!visible_) {
    return false;
  }
  NOTIFYICONDATAW data = BaseData(window_);
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO;
  CopyText(data.szInfoTitle, title);
  CopyText(data.szInfo, body);
  return Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
}

void TrayIcon::RefreshIcon() {
  if (!visible_) {
    return;
  }
  HICON icon = LoadTrayIcon();
  if (icon == nullptr) {
    return;
  }
  NOTIFYICONDATAW data = BaseData(window_);
  data.uFlags = NIF_ICON;
  data.hIcon = icon;
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    DestroyIcon(icon);
    return;
  }
  if (icon_ != nullptr) {
    DestroyIcon(icon_);
  }
  icon_ = icon;
}

void TrayIcon::Remove() {
  if (window_ != nullptr) {
    NOTIFYICONDATAW data = BaseData(window_);
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
  if (icon_ != nullptr) {
    DestroyIcon(icon_);
    icon_ = nullptr;
  }
  window_ = nullptr;
  visible_ = false;
}

bool TrayIcon::visible() const {
  return visible_;
}
