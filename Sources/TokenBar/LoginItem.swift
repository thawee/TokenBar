import OSLog
import ServiceManagement
import SwiftUI

/// Open at login through SMAppService. The system's registration is the source of truth,
/// so the status is re-read rather than kept in UserDefaults.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status
    private(set) var lastError: String?

    @ObservationIgnored private let service = SMAppService.mainApp
    @ObservationIgnored private let log = Logger(subsystem: "local.tokenbar", category: "login-item")

    init() {
        status = service.status
    }

    /// On, or waiting for the user to allow it in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = service.status
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            log.error("\(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        log.notice("open at login: \(String(describing: self.status), privacy: .public)")
    }

    /// The first launch turns it on; after that only the toggle changes it, so turning
    /// it off sticks.
    func enableOnFirstLaunch() {
        let key = "loginItem.configured"
        log.notice("open at login at launch: \(String(describing: self.status), privacy: .public)")
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if status == .notRegistered || status == .notFound { setEnabled(true) }
    }
}

extension SMAppService.Status: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

struct LoginItemToggle: View {
    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if loginItem.needsApproval {
                HStack(spacing: 6) {
                    Text("Allow TokenBar in Login Items to finish.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                        .controlSize(.mini)
                }
            }
            if let error = loginItem.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { loginItem.refresh() }
    }
}
