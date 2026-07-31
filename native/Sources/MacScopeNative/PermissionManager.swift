import Foundation
import ServiceManagement

enum LoginItemState: Equatable, Sendable {
  case disabled
  case enabled
  case requiresApproval
  case unavailable
}

@MainActor
final class PermissionManager: ObservableObject {
  @Published private(set) var loginItemState: LoginItemState = .disabled
  @Published private(set) var loginItemError: String?
  @Published private(set) var isUpdatingLoginItem = false

  var launchesAtLogin: Bool {
    switch loginItemState {
    case .enabled, .requiresApproval: true
    case .disabled, .unavailable: false
    }
  }

  init() {
    refresh()
  }

  func refresh() {
    refreshLoginItemState()
  }

  func setLaunchesAtLogin(_ isEnabled: Bool) {
    guard !isUpdatingLoginItem else { return }
    isUpdatingLoginItem = true
    loginItemError = nil

    do {
      if isEnabled {
        try enableLoginItem()
      } else {
        try disableLoginItem()
      }
    } catch {
      loginItemError = error.localizedDescription
    }

    refreshLoginItemState()
    isUpdatingLoginItem = false

    if isEnabled, loginItemState == .requiresApproval {
      SMAppService.openSystemSettingsLoginItems()
    }
  }

  func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }

  private func refreshLoginItemState() {
    if FileManager.default.fileExists(atPath: Self.launchAgentURL.path) {
      loginItemState = .enabled
      return
    }

    switch SMAppService.mainApp.status {
    case .notRegistered:
      loginItemState = .disabled
    case .enabled:
      loginItemState = .enabled
    case .requiresApproval:
      loginItemState = .requiresApproval
    case .notFound:
      loginItemState = .disabled
    @unknown default:
      loginItemState = .unavailable
    }
  }

  private func enableLoginItem() throws {
    do {
      switch SMAppService.mainApp.status {
      case .notFound:
        try Self.installLaunchAgent()
      case .notRegistered, .enabled, .requiresApproval:
        try SMAppService.mainApp.register()
      @unknown default:
        try Self.installLaunchAgent()
      }
    } catch {
      try Self.installLaunchAgent()
    }
  }

  private func disableLoginItem() throws {
    if FileManager.default.fileExists(atPath: Self.launchAgentURL.path) {
      try FileManager.default.removeItem(at: Self.launchAgentURL)
    }

    switch SMAppService.mainApp.status {
    case .enabled, .requiresApproval:
      try SMAppService.mainApp.unregister()
    case .notRegistered, .notFound:
      break
    @unknown default:
      break
    }
  }

  private static var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
      .appendingPathComponent("com.shenmuoso.macscope.login.plist")
  }

  private static func installLaunchAgent() throws {
    let directory = launchAgentURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let propertyList: [String: Any] = [
      "Label": "com.shenmuoso.macscope.login",
      "ProgramArguments": ["/usr/bin/open", "-gj", Bundle.main.bundleURL.path],
      "RunAtLoad": true,
      "ProcessType": "Interactive",
      "LimitLoadToSessionType": "Aqua",
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: propertyList,
      format: .xml,
      options: 0
    )
    try data.write(to: launchAgentURL, options: .atomic)
  }

}
