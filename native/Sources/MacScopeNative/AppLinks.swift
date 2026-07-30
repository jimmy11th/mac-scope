import AppKit
import Foundation

enum AppLinks {
  static let github = URL(string: "https://github.com/shenmuoso/great-mac-scope")!

  @MainActor
  static func openGitHub() {
    NSWorkspace.shared.open(github)
  }
}
