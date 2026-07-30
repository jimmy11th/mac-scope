import SwiftUI

@main
struct MacScopeNativeApp: App {
  @StateObject private var monitor = SystemMonitor()
  @StateObject private var settings = AppSettings()
  @StateObject private var maintenance = MaintenanceStore()

  var body: some Scene {
    WindowGroup("MacScope") {
      MacScopeRootView(monitor: monitor)
        .environmentObject(monitor)
        .environmentObject(monitor.metrics)
        .environmentObject(settings)
        .environmentObject(maintenance)
        .environment(\.locale, settings.language.locale)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.activeTheme.accentColor)
        .frame(minWidth: 1_020, minHeight: 620)
        .background {
          MainWindowConfigurationView()
            .allowsHitTesting(false)
        }
        .onAppear {
          AppIconController.apply(settings.appIconStyle)
          maintenance.updateLanguage(settings.language)
          monitor.updateRefreshInterval(settings.refreshInterval)
          monitor.start()
        }
        .onChange(of: settings.language) { language in
          maintenance.updateLanguage(language)
        }
        .onChange(of: settings.refreshInterval) { interval in
          monitor.updateRefreshInterval(interval)
        }
    }
    .defaultSize(width: 1_320, height: 800)
    .windowStyle(.titleBar)
    .commands {
      MacScopeCommands(language: settings.language)
    }

    Settings {
      SettingsView()
        .environmentObject(settings)
        .environment(\.locale, settings.language.locale)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.activeTheme.accentColor)
        .frame(width: 660, height: 520)
    }

    Window("MacScope Help", id: "help") {
      HelpView()
        .environmentObject(settings)
        .environment(\.locale, settings.language.locale)
        .preferredColorScheme(settings.appearance.colorScheme)
        .tint(settings.activeTheme.accentColor)
        .frame(minWidth: 680, minHeight: 480)
    }
    .defaultSize(width: 780, height: 560)
    .windowStyle(.titleBar)
  }
}
