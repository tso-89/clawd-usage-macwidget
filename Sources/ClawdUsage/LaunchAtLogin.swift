import Foundation
import ServiceManagement

/// "Open at login", read from and written to macOS itself (SMAppService), not config.json -
/// so the switch can't disagree with System Settings → Login Items. Same approach as Kiten.
enum LaunchAtLogin {
    /// SMAppService registers the running bundle: a bare `swift run` binary has none.
    static var isSupported: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but the user still has to allow it in System Settings → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
