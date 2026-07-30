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
  @EnvironmentObject private var maintenance: MaintenanceStore
  @AppStorage("native.sidebarDestination") private var destinationRaw =
    SidebarDestination.overview.rawValue

  private var destination: SidebarDestination {
    SidebarDestination(rawValue: destinationRaw) ?? .overview
  }

  private var destinationSelection: Binding<SidebarDestination?> {
    Binding(
      get: { destination },
      set: { destinationRaw = ($0 ?? .overview).rawValue }
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
      .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
    } detail: {
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
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
      }
    }
    .sheet(
      isPresented: Binding(
        get: { maintenance.activity != nil },
        set: { if !$0 { maintenance.dismissActivity() } }
      )
    ) {
      MaintenanceActivityView()
        .environmentObject(maintenance)
    }
  }

  private func sidebarRow(_ item: SidebarDestination) -> some View {
    Label(item.title, systemImage: item.systemImage)
      .tag(item)
  }
}
