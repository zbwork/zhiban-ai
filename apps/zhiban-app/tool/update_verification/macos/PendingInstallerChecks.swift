import Foundation

@main
struct PendingInstallerChecks {
    static func main() {
        let installer = PendingUpdateInstaller()
        var calls = 0
        var scheduled: (() -> Void)?
        installer.prepare({ calls += 1 }, versionString: "101")
        precondition(installer.scheduleInstall { scheduled = $0 })
        precondition(calls == 0, "Must return the method result before installation")
        scheduled?()
        precondition(calls == 1)
        precondition(installer.hasPendingInstall && installer.pendingVersionString == "101")
        precondition(installer.install() && calls == 2, "Cancelled termination must allow another attempt")
        installer.clear()
        precondition(!installer.install() && installer.pendingVersionString == nil)
        let intent = UpdateCheckIntent()
        intent.beginBackgroundDownload()
        intent.beginBackgroundDownload() // Rejoining the background cycle retains intent.
        precondition(intent.shouldCapturePendingInstall)
        precondition(intent.finishCycle() && !intent.finishCycle())
        print("Native production updater state checks passed")
    }
}
