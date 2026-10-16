import FlutterMacOS
import Network

/// Observe carriers independently: the default path can remain satisfied by
/// a VPN after Wi-Fi is switched off. No requests or public Internet probes.
final class DesktopNetworkBridge: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var monitors: [NWPathMonitor] = []
  private var observations: [String: Bool] = [:]
  private var pendingChecks: [FlutterResult] = []
  private var sink: FlutterEventSink?
  private let interfaces: [(String, NWInterface.InterfaceType)] = [
    ("wifi", .wifi), ("ethernet", .wiredEthernet), ("mobile", .cellular)
  ]

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "cn.qkfintech.zhiban/network", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "cn.qkfintech.zhiban/network/events", binaryMessenger: messenger)
    super.init()
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard call.method == "check" else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let snapshot = self.snapshot { result(snapshot) }
      else { self.pendingChecks.append(result) }
      self.start()
    }
    events.setStreamHandler(self)
  }

  private var snapshot: [String]? {
    guard observations.count == interfaces.count else { return nil }
    let available = interfaces.compactMap { observations[$0.0] == true ? $0.0 : nil }
    return available.isEmpty ? ["none"] : available
  }

  private func start() {
    guard monitors.isEmpty else { return }
    for (name, type) in interfaces {
      let monitor = NWPathMonitor(requiredInterfaceType: type)
      monitor.pathUpdateHandler = { [weak self] path in
        guard let self = self else { return }
        self.observations[name] = path.status == .satisfied
        guard let snapshot = self.snapshot else { return }
        self.sink?(snapshot)
        let checks = self.pendingChecks
        self.pendingChecks.removeAll()
        checks.forEach { $0(snapshot) }
      }
      monitors.append(monitor)
      monitor.start(queue: .main)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    if let snapshot = snapshot { events(snapshot) }
    start()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    // The window owns the monitors; checks and a new session share the latest
    // snapshot, including changes while Dart has no active subscription.
    return nil
  }

  func dispose() {
    monitors.forEach { $0.cancel() }
    monitors.removeAll()
    sink = nil
    methods.setMethodCallHandler(nil)
    events.setStreamHandler(nil)
    let checks = pendingChecks
    pendingChecks.removeAll()
    checks.forEach { $0(FlutterError(code: "network_monitor_closed", message: "Network monitor closed", details: nil)) }
  }
}
