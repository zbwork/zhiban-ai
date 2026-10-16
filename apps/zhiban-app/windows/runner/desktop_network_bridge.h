#ifndef RUNNER_DESKTOP_NETWORK_BRIDGE_H_
#define RUNNER_DESKTOP_NETWORK_BRIDGE_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <memory>

// Owned by FlutterWindow and destroyed before its engine. Native callbacks
// post to the window; channel calls always run on the platform thread.
class DesktopNetworkBridge {
 public:
  DesktopNetworkBridge(flutter::BinaryMessenger* messenger, HWND window);
  ~DesktopNetworkBridge();
  bool HandleMessage(UINT message);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif
