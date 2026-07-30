import AppKit
import Combine
import Foundation
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Sendable {
  case overview
  case junk
  case applications
  case largeFiles
  case duplicates
  case memory

  var id: String { rawValue }

  var title: LocalizedStringKey {
    switch self {
    case .overview: "Overview"
    case .junk: "Junk Cleanup"
    case .applications: "Applications"
    case .largeFiles: "Large Files"
    case .duplicates: "Duplicates"
    case .memory: "Memory"
    }
  }

  var systemImage: String {
    switch self {
    case .overview: "gauge.with.dots.needle.50percent"
    case .junk: "trash"
    case .applications: "app.dashed"
    case .largeFiles: "externaldrive.badge.exclamationmark"
    case .duplicates: "doc.on.doc"
    case .memory: "memorychip"
    }
  }
}

struct ProcessInspectionRequest: Equatable, Identifiable, Sendable {
  let id = UUID()
  let pid: Int32
}

@MainActor
final class AppNavigation: ObservableObject {
  private static let destinationKey = "native.sidebarDestination"

  @Published var destination: AppDestination {
    didSet { defaults.set(destination.rawValue, forKey: Self.destinationKey) }
  }
  @Published private(set) var processInspectionRequest: ProcessInspectionRequest?

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    destination =
      AppDestination(rawValue: defaults.string(forKey: Self.destinationKey) ?? "") ?? .overview
  }

  func inspectProcess(_ pid: Int32) {
    destination = .overview
    processInspectionRequest = ProcessInspectionRequest(pid: pid)
  }

  func completeProcessInspection(_ request: ProcessInspectionRequest) {
    guard processInspectionRequest?.id == request.id else { return }
    processInspectionRequest = nil
  }
}

@MainActor
enum AppWindowActions {
  static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("MacScope.MainWindow")

  static func activate() {
    NSApp.activate(ignoringOtherApps: true)
  }

  static func openSettings() {
    activate()
    let didOpen = NSApp.sendAction(
      Selector(("showSettingsWindow:")),
      to: nil,
      from: nil
    )
    if !didOpen {
      NSApp.sendAction(
        Selector(("showPreferencesWindow:")),
        to: nil,
        from: nil
      )
    }
  }

  static var mainWindow: NSWindow? {
    NSApp.windows.first { $0.identifier == mainWindowIdentifier }
  }
}
