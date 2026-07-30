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
      VStack(spacing: 0) {
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
        .compactNativeScrollers(clearsBackground: true)

        Divider()
        sidebarFooter
      }
      .background {
        SidebarMaterialView(
          isEnabled: settings.sidebarTransparencyEnabled,
          transparency: settings.sidebarTransparency
        )
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }
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

  private var sidebarFooter: some View {
    VStack(alignment: .leading, spacing: 7) {
      Link(destination: AppLinks.author) {
        GitHubLinkLabel(title: "Author: shenmuoso", iconSize: 12)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .help("Author Homepage")
      Link(destination: AppLinks.github) {
        GitHubLinkLabel(title: "Project: mac-scope", iconSize: 12)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.85)
      .help("Project Homepage")
      Text("Version \(AppMetadata.version)")
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
    .font(.caption)
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
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
