import Cocoa
import FlutterMacOS
import XCTest
@testable import 知办AI

class RunnerTests: XCTestCase {

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

  func testRejectedInteractiveCheckPreservesBackgroundDownloadIntent() {
    let intent = UpdateCheckIntent()
    intent.beginBackgroundDownload()

    XCTAssertFalse(intent.beginInteractiveCheck(canCheckForUpdates: false))
    XCTAssertTrue(intent.shouldCapturePendingInstall)
  }

  func testFinishingBackgroundCycleReturnsNotificationResponsibility() {
    let intent = UpdateCheckIntent()
    intent.beginBackgroundDownload()

    XCTAssertTrue(intent.finishCycle())
    XCTAssertFalse(intent.shouldCapturePendingInstall)
    XCTAssertFalse(intent.finishCycle())
  }

  func testPendingInstallCanBeScheduledAfterMethodResult() {
    let installer = PendingUpdateInstaller()
    var installed = false
    var scheduledInstall: (() -> Void)?
    installer.prepare { installed = true }

    XCTAssertTrue(installer.scheduleInstall { scheduledInstall = $0 })
    XCTAssertFalse(installed)

    scheduledInstall?()
    XCTAssertTrue(installed)
  }

}
