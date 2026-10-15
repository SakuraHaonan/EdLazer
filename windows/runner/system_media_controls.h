#ifndef RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#define RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/binary_messenger.h>
#include <memory>

// WinRT callbacks are marshalled through a window message before touching the
// Flutter channel. The implementation owns/revokes every native event handler.
class SystemMediaControls {
 public:
  SystemMediaControls(flutter::BinaryMessenger* messenger, HWND window);
  ~SystemMediaControls();
  bool HandleWindowMessage(UINT message, LPARAM parameter);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
#endif
