import Cocoa
import FlutterMacOS
import Sparkle

final class PendingUpdateInstaller {
  private var handler: (() -> Void)?
  private(set) var pendingVersionString: String?

  var hasPendingInstall: Bool {
    handler != nil
  }

  func prepare(_ handler: @escaping () -> Void, versionString: String? = nil) {
    self.handler = handler
    self.pendingVersionString = versionString
  }

  @discardableResult
  func install() -> Bool {
    guard let handler else {
      return false
    }
    // Sparkle permits retrying this handler when the app cancels termination.
    // Do not lose the install action before installation actually succeeds.
    handler()
    return true
  }

  func clear() {
    handler = nil
    pendingVersionString = nil
  }

  @discardableResult
  func scheduleInstall(
    using scheduler: (@escaping () -> Void) -> Void = { action in
      DispatchQueue.main.async(execute: action)
    }
  ) -> Bool {
    guard hasPendingInstall else {
      return false
    }
    scheduler { [weak self] in
      self?.install()
    }
    return true
  }
}

final class UpdateCheckIntent {
  private(set) var shouldCapturePendingInstall = false

  func beginBackgroundDownload() {
    shouldCapturePendingInstall = true
  }

  func clear() {
    shouldCapturePendingInstall = false
  }

  @discardableResult
  func finishCycle() -> Bool {
    let shouldNotify = shouldCapturePendingInstall
    shouldCapturePendingInstall = false
    return shouldNotify
  }
}

/// 静默更新用户驱动：不展示任何 Sparkle 原生 UI（更新确认框、下载进度、
/// 就绪安装提示等）。更新状态与安装交互全部由 Flutter 侧栏指示器承担：
/// 发现更新 → 自动下载 → 安装/重启时机仍由 AppDelegate 的
/// `willInstallUpdateOnQuit`（Flutter 点击「安装」）控制。
final class SilentUserDriver: NSObject, SPUUserDriver {
  private let onExtractionStarted: () -> Void
  private let onExtractionProgress: (Double) -> Void
  private let onDownloadProgress: (UInt64, UInt64) -> Void
  private var expectedDownloadLength: UInt64 = 0
  private var receivedDownloadLength: UInt64 = 0

  init(
    onExtractionStarted: @escaping () -> Void,
    onExtractionProgress: @escaping (Double) -> Void,
    onDownloadProgress: @escaping (UInt64, UInt64) -> Void
  ) {
    self.onExtractionStarted = onExtractionStarted
    self.onExtractionProgress = onExtractionProgress
    self.onDownloadProgress = onDownloadProgress
  }

  func show(
    _ request: SPUUpdatePermissionRequest,
    reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(SUUpdatePermissionResponse(
      automaticUpdateChecks: true, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

  func showUpdateFound(
    with appcastItem: SUAppcastItem,
    state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    // 静默进入下载；information-only 更新不适用安装，直接忽略。
    reply(appcastItem.isInformationOnlyUpdate ? .dismiss : .install)
  }

  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    expectedDownloadLength = 0
    receivedDownloadLength = 0
  }
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    self.expectedDownloadLength = expectedContentLength
    onDownloadProgress(receivedDownloadLength, expectedContentLength)
  }
  func showDownloadDidReceiveData(ofLength length: UInt64) {
    receivedDownloadLength += length
    onDownloadProgress(receivedDownloadLength, expectedDownloadLength)
  }
  func showDownloadDidStartExtractingUpdate() {
    onExtractionStarted()
  }
  func showExtractionReceivedProgress(_ progress: Double) {
    onExtractionProgress(progress)
  }
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    reply(.install)
  }
  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}
  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
  }
  func dismissUpdateInstallation() {}
}

@main
class AppDelegate: FlutterAppDelegate, SPUUpdaterDelegate {
  private var overrideFeedURLString: String?
  private let updateCheckIntent = UpdateCheckIntent()
  private let pendingUpdateInstaller = PendingUpdateInstaller()

  var updateMethodChannel: FlutterMethodChannel?

  private lazy var updater: SPUUpdater = {
    let updater = SPUUpdater(
      hostBundle: Bundle.main,
      applicationBundle: Bundle.main,
      userDriver: SilentUserDriver(
        onExtractionStarted: { [weak self] in
          self?.pushUpdateEvent(["event": "installPreparing"])
        },
        onExtractionProgress: { [weak self] progress in
          self?.pushUpdateEvent(["event": "installPreparing", "progress": progress])
        },
        onDownloadProgress: { [weak self] received, total in
          self?.pushUpdateEvent(["event": "downloadProgress", "receivedBytes": received, "totalBytes": total])
        }
      ),
      delegate: self
    )
    // Downloads are coordinated with durable Flutter storage, including for
    // users whose Sparkle preferences previously enabled automatic checks.
    updater.automaticallyChecksForUpdates = false
    do {
      try updater.start()
    } catch {
      NSLog("[Update] source=sparkle failed to start Sparkle updater domain=\((error as NSError).domain) code=\((error as NSError).code)")
    }
    return updater
  }()

  // 关闭最后一个窗口不退出程序：配合 MainFlutterWindow.performClose（点关闭按钮仅隐藏窗口），
  // 应用继续在 Dock 后台运行，直到用户 ⌘Q / 菜单「退出」。
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // 点击 Dock 图标时，如果没有可见窗口，则重新显示主窗口并激活。
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      for window in sender.windows where window is MainFlutterWindow {
        window.makeKeyAndOrderFront(self)
      }
      NSApp.activate(ignoringOtherApps: true)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  func installUpdateInBackgroundFromFlutter(feedURLString: String? = nil) -> Bool {
    NSLog("[Update] source=sparkle immediate install requested")
    setUpdateFeedURLString(feedURLString)
    guard updater.canCheckForUpdates else {
      return false
    }
    updateCheckIntent.beginBackgroundDownload()
    updater.automaticallyDownloadsUpdates = true
    updater.checkForUpdatesInBackground()
    NSLog("[Update] source=sparkle immediate install check started")
    return true
  }

  func installPendingUpdateFromFlutter() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let scheduled = pendingUpdateInstaller.scheduleInstall()
    NSLog("[Update] source=sparkle installPendingUpdateFromFlutter scheduled=\(scheduled)")
    return scheduled
  }

  func currentUpdateState() -> [String: Any] {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    NSLog("[Update] source=sparkle state current_version=\(version), current_build=\(currentBuild), pending=\(pendingUpdateInstaller.hasPendingInstall), "
      + "build=\(pendingUpdateInstaller.pendingVersionString ?? ""), "
      + "canCheck=\(updater.canCheckForUpdates), "
      + "session=\(updater.sessionInProgress)")
    return [
      "pendingInstall": pendingUpdateInstaller.hasPendingInstall,
      "pendingBuildNumber": pendingUpdateInstaller.pendingVersionString ?? "",
      "canCheckForUpdates": updater.canCheckForUpdates,
      "sessionInProgress": updater.sessionInProgress,
    ]
  }

  func updateFeedURLString() -> String? {
    if let overrideFeedURLString, !overrideFeedURLString.isEmpty {
      return overrideFeedURLString
    }
    if let feedURL = updater.feedURL {
      return feedURL.absoluteString
    }
    return Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
  }

  func setUpdateFeedURLString(_ value: String?) {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    overrideFeedURLString = trimmed.isEmpty ? nil : trimmed
    NSLog("[Update] source=sparkle feed override set=\(!trimmed.isEmpty)")
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    return overrideFeedURLString
  }

  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    NSLog("[Update] source=sparkle valid update latest_version=\(item.displayVersionString), latest_build=\(item.versionString)")
  }

  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
    let packageType = item.isDeltaUpdate ? "delta" : "full"
    NSLog("[Update] source=sparkle Sparkle download started sparkle_package=\(packageType), latest_version=\(item.displayVersionString), latest_build=\(item.versionString)")
    pushUpdateEvent(["event": "sparkleDownloadStarted", "packageType": packageType, "version": item.displayVersionString, "buildNumber": item.versionString])
  }

  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    NSLog("[Update] source=sparkle Sparkle download complete latest_version=\(item.displayVersionString), latest_build=\(item.versionString)")
    let packageType = item.isDeltaUpdate ? "delta" : "full"
    pushUpdateEvent(["event": "sparkleDownloadComplete", "packageType": packageType, "version": item.displayVersionString, "buildNumber": item.versionString])
  }

  func updater(
    _ updater: SPUUpdater,
    willInstallUpdateOnQuit item: SUAppcastItem,
    immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
  ) -> Bool {
    if updateCheckIntent.finishCycle() {
      NSLog("[Update] source=sparkle willInstallUpdateOnQuit: storing pending install handler")
      pendingUpdateInstaller.prepare(immediateInstallHandler, versionString: item.versionString)
      NSLog("[Update] source=sparkle willInstallUpdateOnQuit: handler set")
      pushUpdateEvent(["event": "installReady", "version": item.displayVersionString, "buildNumber": item.versionString])
      return true
    }
    return false
  }

  private func pushUpdateEvent(_ args: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.updateMethodChannel?.invokeMethod("updateEvent", arguments: args)
    }
  }

  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
    NSLog("[Update] source=sparkle updaterDidNotFindUpdate domain=\((error as NSError).domain) code=\((error as NSError).code)")
    updateCheckIntent.finishCycle()
    pushUpdateEvent(["event": "notFound"])
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    var currentError: NSError? = error as NSError
    var depth = 0
    while let failure = currentError, depth < 8 {
      NSLog("[Update] source=sparkle didAbortWithError depth=\(depth) domain=\(failure.domain) code=\(failure.code)")
      currentError = failure.userInfo[NSUnderlyingErrorKey] as? NSError
      depth += 1
    }
    updateCheckIntent.finishCycle()
    pendingUpdateInstaller.clear()
    pushUpdateEvent(["event": "failed"])
  }

  func userDidCancelDownload(_ updater: SPUUpdater) {
    updateCheckIntent.finishCycle()
    pushUpdateEvent(["event": "cancelled"])
  }
}
