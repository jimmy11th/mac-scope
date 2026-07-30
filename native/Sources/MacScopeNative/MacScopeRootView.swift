import SwiftUI

struct MacScopeRootView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var navigation: AppNavigation

  private var destinationSelection: Binding<AppDestination?> {
    Binding(
      get: { navigation.destination },
      set: {
        let nextDestination = $0 ?? .overview
        guard navigation.destination != nextDestination else { return }
        if navigation.destination == .overview {
          monitor.setProcessSampling(false, for: .overview)
        }
        navigation.destination = nextDestination
        if nextDestination == .overview {
          monitor.setProcessSampling(true, for: .overview)
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
          Button(action: AppWindowActions.openSettings) {
            Label("Settings", systemImage: "gearshape")
          }
          .help("Settings")
        }
      }
    }
    .onAppear {
      monitor.setProcessSampling(navigation.destination == .overview, for: .overview)
    }
    .onDisappear {
      monitor.setProcessSampling(false, for: .overview)
    }
  }

  private func sidebarRow(_ item: AppDestination) -> some View {
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
    switch navigation.destination {
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

}
