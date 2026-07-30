import SwiftUI

@main
struct MacScopeNativeApp: App {
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var settings = AppSettings()

  var body: some Scene {
    WindowGroup("MacScope") {
      DashboardView()
        .environmentObject(monitor)
        .environmentObject(settings)
        .frame(minWidth: 920, minHeight: 600)
        .onAppear {
          monitor.refreshInterval = settings.refreshInterval
          monitor.start()
        }
        .onChange(of: settings.refreshInterval) { interval in
          monitor.refreshInterval = interval
          monitor.refreshNow()
        }
    }
    .defaultSize(width: 1_180, height: 760)
    .windowStyle(.titleBar)

    Settings {
      SettingsView()
        .environmentObject(settings)
        .frame(width: 430, height: 230)
    }
  }
}
