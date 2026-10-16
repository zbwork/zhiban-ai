import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var updateChannel: FlutterMethodChannel?
  private var localCodingProjectChannel: FlutterMethodChannel?
  private var localAgentSleepObserver: NSObjectProtocol?
  private var localComputerBridge: LocalComputerBridge?
  private var desktopNetworkBridge: DesktopNetworkBridge?

  deinit {
    desktopNetworkBridge?.dispose()
    if let observer = localAgentSleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    desktopNetworkBridge = DesktopNetworkBridge(messenger: flutterViewController.engine.binaryMessenger)
    localComputerBridge = LocalComputerBridge(messenger: flutterViewController.engine.binaryMessenger)
    let localLifecycle = FlutterMethodChannel(name: "nexwork/local_agent_lifecycle", binaryMessenger: flutterViewController.engine.binaryMessenger)
    localAgentSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
      localLifecycle.invokeMethod("willSleep", arguments: nil)
    }


    // F16 RTC: 注册 DingRTC native bridge (MethodChannel + EventChannel + 视频 PlatformView 工厂)。
    DingRtcBridge.register(
      messenger: flutterViewController.engine.binaryMessenger,
      registrar: flutterViewController.registrar(forPlugin: "EasyoRtcVideoView")
    )
    // F16 RTC: 被叫来电「屏幕级」原生浮窗（NSPanel）。
    RtcIncomingPanelBridge.register(messenger: flutterViewController.engine.binaryMessenger)
    // F16 RTC: 统一会议模型 · 接通后独立会议窗口（NSWindow，复用同一 DingRtcEngine）。
    RtcMeetingWindowBridge.register(messenger: flutterViewController.engine.binaryMessenger)

    updateChannel = FlutterMethodChannel(
      name: "cn.qkfintech.zhiban/update",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    (NSApplication.shared.delegate as? AppDelegate)?.updateMethodChannel = updateChannel
    let notificationChannel = FlutterMethodChannel(
      name: "cn.qkfintech.zhiban/notification",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    notificationChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "setBadgeCount":
        let args = call.arguments as? [String: Any]
        let count = args?["count"] as? Int ?? 0
        if count > 0 {
          NSApp.dockTile.badgeLabel = "\(count)"
        } else {
          NSApp.dockTile.badgeLabel = nil
        }
        result(nil)
      case "clearNotifications":
        NSUserNotificationCenter.default.removeAllDeliveredNotifications()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    localCodingProjectChannel = FlutterMethodChannel(
      name: "cn.qkfintech.zhiban/local-coding-project",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    localCodingProjectChannel?.setMethodCallHandler { call, result in
      guard call.method == "createProjectBookmark" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let path = args["path"] as? String,
        !path.isEmpty,
        path.hasPrefix("/")
      else {
        result(FlutterError(
          code: "project_selection_invalid",
          message: "项目目录选择无效，请重新选择",
          details: nil
        ))
        return
      }
      do {
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw LocalCodingProjectBookmarkError.invalidDirectory
        }
        let bookmark = try url.bookmarkData(
          options: [],
          includingResourceValuesForKeys: [.isDirectoryKey],
          relativeTo: nil
        )
        guard !bookmark.isEmpty, bookmark.count <= 64 * 1024 else {
          throw LocalCodingProjectBookmarkError.invalidBookmark
        }
        result(bookmark.base64EncodedString())
      } catch {
        result(FlutterError(
          code: "project_permission_failed",
          message: "无法获得项目目录权限，请重新选择",
          details: nil
        ))
      }
    }

    updateChannel?.setMethodCallHandler { call, result in
      switch call.method {
      case "installUpdateInBackground":
        let args = call.arguments as? [String: Any]
        let feedURL = args?["feedUrl"] as? String
        let launched = (NSApplication.shared.delegate as? AppDelegate)?.installUpdateInBackgroundFromFlutter(feedURLString: feedURL) ?? false
        result(launched)
      case "installPendingUpdate":
        let launched = (NSApplication.shared.delegate as? AppDelegate)?.installPendingUpdateFromFlutter() ?? false
        result(launched)
      case "getUpdateState":
        let state = (NSApplication.shared.delegate as? AppDelegate)?.currentUpdateState() ?? [
          "pendingInstall": false,
          "canCheckForUpdates": false,
        ]
        result(state)
      case "getUpdateFeedUrl":
        result((NSApplication.shared.delegate as? AppDelegate)?.updateFeedURLString())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ 隐藏标题文字
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true

    // 居中显示
    self.center()

    // ✅ 允许内容铺到标题栏区域
    self.styleMask.insert(.fullSizeContentView)

    super.awakeFromNib()
  }

  // 点击红色关闭按钮（或 ⌘W）时不退出程序，仅隐藏窗口；应用继续在 Dock 运行，
  // 点击 Dock 图标可重新显示（见 AppDelegate.applicationShouldHandleReopen）。
  // 真正退出仍走 ⌘Q / 菜单「退出」。
  override func performClose(_ sender: Any?) {
    self.orderOut(sender)
  }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseUp, event.clickCount == 2 {
      let titleBarHeight: CGFloat = 40
      if event.locationInWindow.y >= self.frame.height - titleBarHeight {
        self.performZoom(nil)
        return
      }
    }
    super.sendEvent(event)
  }
}

private enum LocalCodingProjectBookmarkError: Error {
  case invalidDirectory
  case invalidBookmark
}
