#include "drop_target.h"

#include <shellapi.h>

#include <algorithm>
#include <cwchar>
#include <cwctype>
#include <string>
#include <utility>
#include <vector>

#include "utils.h"

namespace {

constexpr UINT kMaxPaths = 1001;

FORMATETC HdropFormat() {
  return FORMATETC{CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool OffersDiskPaths(IDataObject* data) {
  FORMATETC hdrop = HdropFormat();
  return data->QueryGetData(&hdrop) == S_OK;
}

std::wstring LongTempPath() {
  wchar_t buffer[MAX_PATH + 1];
  const DWORD length = ::GetTempPathW(MAX_PATH, buffer);
  if (length == 0 || length > MAX_PATH) {
    return std::wstring();
  }
  std::wstring temp(buffer, length);
  wchar_t long_buffer[MAX_PATH + 1];
  const DWORD long_length = ::GetLongPathNameW(temp.c_str(), long_buffer, MAX_PATH);
  if (long_length > 0 && long_length <= MAX_PATH) {
    temp.assign(long_buffer, long_length);
  }
  if (!temp.empty() && temp.back() != L'\\') {
    temp.push_back(L'\\');
  }
  return temp;
}

bool InsideExtractionFolder(const std::wstring& path, const std::wstring& temp) {
  if (temp.empty() || path.size() <= temp.size() + 4) {
    return false;
  }
  if (::_wcsnicmp(path.c_str(), temp.c_str(), temp.size()) != 0) {
    return false;
  }
  const wchar_t* rest = path.c_str() + temp.size();
  return ::_wcsnicmp(rest, L"Temp", 4) == 0 && std::iswdigit(rest[4]) != 0;
}

}

DropTarget::DropTarget(HWND view,
                       flutter::MethodChannel<flutter::EncodableValue>* channel)
    : view_(view), channel_(channel) {}

HRESULT STDMETHODCALLTYPE DropTarget::QueryInterface(REFIID riid,
                                                     void** object) {
  if (object == nullptr) {
    return E_POINTER;
  }
  if (riid == IID_IUnknown || riid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE DropTarget::AddRef() {
  return static_cast<ULONG>(::InterlockedIncrement(&references_));
}

ULONG STDMETHODCALLTYPE DropTarget::Release() {
  const LONG remaining = ::InterlockedDecrement(&references_);
  if (remaining == 0) {
    delete this;
  }
  return static_cast<ULONG>(remaining);
}

HRESULT STDMETHODCALLTYPE DropTarget::DragEnter(IDataObject* data,
                                                DWORD key_state, POINTL point,
                                                DWORD* effect) {
  accepting_ = data != nullptr && (*effect & DROPEFFECT_COPY) != 0 &&
               OffersDiskPaths(data);
  if (!accepting_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  *effect = DROPEFFECT_COPY;
  last_point_ = ToClient(point);
  NotifyPoint("enter", last_point_);
  return S_OK;
}

HRESULT STDMETHODCALLTYPE DropTarget::DragOver(DWORD key_state, POINTL point,
                                               DWORD* effect) {
  if (!accepting_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  *effect = DROPEFFECT_COPY;
  const POINT current = ToClient(point);
  if (current.x != last_point_.x || current.y != last_point_.y) {
    last_point_ = current;
    NotifyPoint("over", current);
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE DropTarget::DragLeave() {
  if (accepting_) {
    accepting_ = false;
    Notify("leave", nullptr);
  }
  return S_OK;
}

HRESULT STDMETHODCALLTYPE DropTarget::Drop(IDataObject* data, DWORD key_state,
                                           POINTL point, DWORD* effect) {
  const bool was_accepting = accepting_;
  accepting_ = false;
  *effect = DROPEFFECT_NONE;
  if (!was_accepting || data == nullptr) {
    return S_OK;
  }

  FORMATETC hdrop_format = HdropFormat();
  STGMEDIUM medium = {};
  if (FAILED(data->GetData(&hdrop_format, &medium))) {
    Notify("leave", nullptr);
    return S_OK;
  }

  std::vector<std::wstring> paths;
  UINT count = 0;
  if (medium.tymed == TYMED_HGLOBAL && medium.hGlobal != nullptr) {
    HDROP hdrop = reinterpret_cast<HDROP>(medium.hGlobal);
    count = ::DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
    const UINT limit = std::min(count, kMaxPaths);
    for (UINT i = 0; i < limit; i++) {
      const UINT length = ::DragQueryFileW(hdrop, i, nullptr, 0);
      if (length == 0) {
        continue;
      }
      std::wstring path(length + 1, L'\0');
      const UINT copied = ::DragQueryFileW(hdrop, i, path.data(), length + 1);
      path.resize(copied);
      if (!path.empty()) {
        paths.push_back(std::move(path));
      }
    }
  }
  ::ReleaseStgMedium(&medium);

  const std::wstring temp = LongTempPath();
  const bool extracted =
      std::any_of(paths.begin(), paths.end(), [&temp](const std::wstring& path) {
        return InsideExtractionFolder(path, temp);
      });

  flutter::EncodableList encoded;
  for (const std::wstring& path : paths) {
    const std::string utf8 = Utf8FromUtf16(path.c_str());
    if (!utf8.empty()) {
      encoded.emplace_back(utf8);
    }
  }
  if (extracted || encoded.empty()) {
    Notify("leave", nullptr);
    return S_OK;
  }

  const POINT client = ToClient(point);
  *effect = DROPEFFECT_COPY;
  Notify("drop", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                     {flutter::EncodableValue("x"),
                      flutter::EncodableValue(static_cast<int>(client.x))},
                     {flutter::EncodableValue("y"),
                      flutter::EncodableValue(static_cast<int>(client.y))},
                     {flutter::EncodableValue("count"),
                      flutter::EncodableValue(static_cast<int>(count))},
                     {flutter::EncodableValue("paths"),
                      flutter::EncodableValue(std::move(encoded))},
                 }));
  return S_OK;
}

POINT DropTarget::ToClient(POINTL point) const {
  POINT client = {point.x, point.y};
  ::ScreenToClient(view_, &client);
  return client;
}

void DropTarget::Notify(const char* method,
                        std::unique_ptr<flutter::EncodableValue> arguments) {
  channel_->InvokeMethod(method, std::move(arguments));
}

void DropTarget::NotifyPoint(const char* method, POINT point) {
  Notify(method, std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                     {flutter::EncodableValue("x"),
                      flutter::EncodableValue(static_cast<int>(point.x))},
                     {flutter::EncodableValue("y"),
                      flutter::EncodableValue(static_cast<int>(point.y))},
                 }));
}
