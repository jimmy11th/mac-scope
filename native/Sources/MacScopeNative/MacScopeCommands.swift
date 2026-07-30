import SwiftUI

struct MacScopeCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let language: AppLanguage

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button(localized("About MacScope")) {
        AboutPanel.show(language: language)
      }
    }

    CommandGroup(replacing: .help) {
      Button(localized("MacScope Help")) {
        openWindow(id: "help")
      }
      .keyboardShortcut("/", modifiers: [.command, .shift])

      Divider()

      Button(localized("View Project on GitHub"), action: AppLinks.openGitHub)
    }
  }

  private func localized(_ key: String) -> String {
    AppLocalization.string(key, language: language)
  }
}
