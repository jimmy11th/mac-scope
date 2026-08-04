import SwiftUI

@main
@MainActor
struct MacScopeNativeApp: App {
  @StateObject private var runtime = AppRuntime()

  var body: some Scene {
    Window("MacScope", id: "main") {
      MacScopeRootView()
        .environmentObject(runtime.monitor)
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.settings)
        .environmentObject(runtime.maintenance)
        .environmentObject(runtime.navigation)
        .environmentObject(runtime.mouseScrollReverser)
        .environmentObject(runtime.mihomo)
        .environmentObject(runtime.developerServices)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 1_020, minHeight: 620)
        .background {
          MainWindowConfigurationView()
            .allowsHitTesting(false)
        }
    }
    .defaultSize(width: 1_320, height: 800)
    .windowStyle(.titleBar)
    .commands {
      MacScopeCommands(language: runtime.settings.language)
    }

    Settings {
      SettingsView()
        .environmentObject(runtime.settings)
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.mouseScrollReverser)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(width: 840, height: 620)
        .background {
          SidebarHostingWindowConfigurationView()
            .allowsHitTesting(false)
        }
    }

    MenuBarExtra(
      isInserted: Binding(
        get: { runtime.settings.menuBarEnabled },
        set: { isEnabled in
          guard runtime.settings.menuBarEnabled != isEnabled else { return }
          runtime.settings.menuBarEnabled = isEnabled
        }
      )
    ) {
      MenuBarDashboardView()
        .environmentObject(runtime.monitor)
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.settings)
        .environmentObject(runtime.navigation)
        .environmentObject(runtime.mihomo)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
    } label: {
      MenuBarStatusLabel()
        .environmentObject(runtime.monitor.metrics)
        .environmentObject(runtime.settings)
        .environment(\.locale, runtime.settings.language.locale)
    }
    .menuBarExtraStyle(.window)

    Window("MacScope Help", id: "help") {
      HelpView()
        .environmentObject(runtime.settings)
        .environment(\.locale, runtime.settings.language.locale)
        .preferredColorScheme(runtime.settings.appearance.colorScheme)
        .tint(runtime.settings.activeTheme.accentColor)
        .frame(minWidth: 680, minHeight: 480)
    }
    .defaultSize(width: 780, height: 560)
    .windowStyle(.titleBar)
  }
}
