import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // ghostty-ar: never use upstream's appcast. Its updates are signed with
        // the key in Info.plist, so Sparkle would accept one and replace this
        // build with stock Ghostty, removing bidi. This fork publishes no
        // appcast, so a manual check just reports that it found nothing.
        return "https://github.com/Haddadmj/ghostty-ar/releases/latest/download/appcast.xml"
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
