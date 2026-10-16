#include <winsock2.h>
#include "desktop_network_bridge.h"

#include <iphlpapi.h>
#include <netioapi.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <set>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Sink = flutter::EventSink<Value>;
using StreamError = flutter::StreamHandlerError<Value>;

UINT NetworkMessage() {
  static const UINT message = RegisterWindowMessageW(L"Zhiban.PhysicalNetworkChanged");
  return message;
}

DWORD ReadCarriers(flutter::EncodableList& values) {
  MIB_IF_TABLE2* table = nullptr;
  const DWORD error = GetIfTable2(&table);
  if (error != NO_ERROR) return error;
  std::set<std::string> types;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& row = table->Table[i];
    // TAP/TUN, Hyper-V, loopback and dormant hardware cannot prove a carrier.
    if (!row.InterfaceAndOperStatusFlags.HardwareInterface ||
        row.InterfaceAndOperStatusFlags.FilterInterface ||
        row.OperStatus != IfOperStatusUp ||
        row.MediaConnectState != MediaConnectStateConnected) continue;
    switch (row.Type) {
      case IF_TYPE_IEEE80211: types.insert("wifi"); break;
      case IF_TYPE_ETHERNET_CSMACD:
      case IF_TYPE_IEEE1394: types.insert("ethernet"); break;
      case IF_TYPE_WWANPP:
      case IF_TYPE_WWANPP2: types.insert("mobile"); break;
      default: break;
    }
  }
  FreeMibTable(table);
  if (types.empty()) types.insert("none");
  for (const auto& type : types) values.emplace_back(type);
  return NO_ERROR;
}
}  // namespace

struct DesktopNetworkBridge::Impl {
  HWND window;
  HANDLE notification = nullptr;
  std::unique_ptr<Sink> sink;
  flutter::MethodChannel<Value> methods;
  flutter::EventChannel<Value> events;

  Impl(flutter::BinaryMessenger* messenger, HWND target)
      : window(target),
        methods(messenger, "cn.qkfintech.zhiban/network",
                &flutter::StandardMethodCodec::GetInstance()),
        events(messenger, "cn.qkfintech.zhiban/network/events",
               &flutter::StandardMethodCodec::GetInstance()) {
    // Initialize the registered message before any worker callback.
    NetworkMessage();
    methods.SetMethodCallHandler([](const auto& call, auto result) {
      if (call.method_name() != "check") {
        result->NotImplemented();
        return;
      }
      flutter::EncodableList values;
      const DWORD error = ReadCarriers(values);
      if (error == NO_ERROR) result->Success(Value(values));
      else result->Error("network_check_failed", std::to_string(error));
    });
    events.SetStreamHandler(std::make_unique<flutter::StreamHandlerFunctions<Value>>(
        [this](const Value*, std::unique_ptr<Sink>&& next) -> std::unique_ptr<StreamError> {
          Stop();
          sink = std::move(next);
          const DWORD error = NotifyIpInterfaceChange(AF_UNSPEC, Changed, this,
                                                     FALSE, &notification);
          if (error != NO_ERROR) {
            sink.reset();
            notification = nullptr;
            return std::make_unique<StreamError>("network_monitor_failed", std::to_string(error), nullptr);
          }
          Publish();
          return nullptr;
        },
        [this](const Value*) -> std::unique_ptr<StreamError> {
          Stop();
          return nullptr;
        }));
  }

  static void CALLBACK Changed(void* context, MIB_IPINTERFACE_ROW*, MIB_NOTIFICATION_TYPE) {
    const auto* self = static_cast<Impl*>(context);
    PostMessageW(self->window, NetworkMessage(), 0, 0);
  }

  void Publish() {
    if (!sink) return;
    flutter::EncodableList values;
    const DWORD error = ReadCarriers(values);
    if (error == NO_ERROR) sink->Success(Value(values));
    else sink->Error("network_check_failed", std::to_string(error));
  }

  void Stop() {
    if (notification) {
      // Called on platform thread, never from Changed; waits for callbacks.
      CancelMibChangeNotify2(notification);
      notification = nullptr;
    }
    sink.reset();
  }

  ~Impl() {
    Stop();
    methods.SetMethodCallHandler(nullptr);
    events.SetStreamHandler(nullptr);
  }
};

DesktopNetworkBridge::DesktopNetworkBridge(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>(messenger, window)) {}
DesktopNetworkBridge::~DesktopNetworkBridge() = default;

bool DesktopNetworkBridge::HandleMessage(UINT message) {
  if (message != NetworkMessage()) return false;
  impl_->Publish();
  return true;
}
