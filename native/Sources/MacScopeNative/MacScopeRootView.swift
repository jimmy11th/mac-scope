import AppKit
import SwiftUI

private enum SidebarDestination: String, CaseIterable, Identifiable {
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

struct MacScopeRootView: View {
  private static let destinationKey = "native.sidebarDestination"

  let monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.openWindow) private var openWindow
  @State private var destination: SidebarDestination

  init(monitor: SystemMonitor) {
    self.monitor = monitor
    let savedDestination = UserDefaults.standard.string(forKey: Self.destinationKey)
    _destination = State(
      initialValue: SidebarDestination(rawValue: savedDestination ?? "") ?? .overview
    )
  }

  private var destinationSelection: Binding<SidebarDestination?> {
    Binding(
      get: { destination },
      set: {
        let nextDestination = $0 ?? .overview
        guard destination != nextDestination else { return }
        if destination == .overview {
          monitor.setProcessSamplingEnabled(false)
        }
        destination = nextDestination
        if nextDestination == .overview {
          monitor.setProcessSamplingEnabled(true)
        }
        let rawValue = nextDestination.rawValue
        DispatchQueue.main.async {
          UserDefaults.standard.set(rawValue, forKey: Self.destinationKey)
        }
      }
    )
  }

  var body: some View {
    NavigationSplitView {
      List(selection: destinationSelection) {
        Section("Monitor") {
          sidebarRow(.overview)
        }
        Section("System Tools") {
          sidebarRow(.junk)
          sidebarRow(.applications)
          sidebarRow(.largeFiles)
          sidebarRow(.duplicates)
          sidebarRow(.memory)
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .background {
        SidebarMaterialView(
          isEnabled: settings.sidebarTransparencyEnabled,
          transparency: settings.sidebarTransparency
        )
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
      .compactNativeScrollers(clearsBackground: true)
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    } detail: {
      detailContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
    }
    .navigationSplitViewStyle(.balanced)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Menu {
          Button {
            openWindow(id: "help")
          } label: {
            Label("MacScope Help", systemImage: "questionmark.circle")
          }

          Button(action: AppLinks.openGitHub) {
            Label(
              "View Project on GitHub",
              systemImage: "chevron.left.forwardslash.chevron.right"
            )
          }

          Divider()

          Button {
            AboutPanel.show(language: settings.language)
          } label: {
            Label("About MacScope", systemImage: "info.circle")
          }
        } label: {
          Label("Help & Information", systemImage: "questionmark.circle")
        }
        .help("Help & Information")
      }

      ToolbarItem(placement: .primaryAction) {
        if #available(macOS 14.0, *) {
          SettingsLink {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Settings")
        } else {
          Button(action: openSettings) {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Settings")
        }
      }
    }
    .onAppear {
      monitor.setProcessSamplingEnabled(destination == .overview)
    }
  }

  private func sidebarRow(_ item: SidebarDestination) -> some View {
    Label(item.title, systemImage: item.systemImage)
      .tag(item)
      .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private var detailContent: some View {
    switch destination {
    case .overview:
      DashboardView()
    case .junk:
      JunkCleanupView()
    case .applications:
      ApplicationsToolView()
    case .largeFiles:
      FileCleanupView(tool: .largeFiles)
    case .duplicates:
      FileCleanupView(tool: .duplicates)
    case .memory:
      MemoryToolView()
    }
  }

  private func openSettings() {
    NSApp.activate(ignoringOtherApps: true)
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
}
