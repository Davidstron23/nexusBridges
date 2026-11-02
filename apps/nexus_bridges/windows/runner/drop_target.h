#ifndef RUNNER_DROP_TARGET_H_
#define RUNNER_DROP_TARGET_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <ole2.h>
#include <windows.h>

#include <memory>

class DropTarget : public IDropTarget {
 public:
  DropTarget(HWND view,
             flutter::MethodChannel<flutter::EncodableValue>* channel);

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                           void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD key_state,
                                      POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state, POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD key_state,
                                 POINTL point, DWORD* effect) override;

 private:
  ~DropTarget() = default;

  POINT ToClient(POINTL point) const;
  void Notify(const char* method,
              std::unique_ptr<flutter::EncodableValue> arguments);
  void NotifyPoint(const char* method, POINT point);

  LONG references_ = 1;
  HWND view_;
  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  bool accepting_ = false;
  POINT last_point_ = {0, 0};
};

#endif
