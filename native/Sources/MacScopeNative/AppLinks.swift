import AppKit
import Foundation

enum AppLinks {
  static let author = URL(string: "https://github.com/shenmuoso")!
  static let github = URL(string: "https://github.com/shenmuoso/mac-scope")!

  @MainActor
  static func openGitHub() {
    NSWorkspace.shared.open(github)
  }
}

enum AppMetadata {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.8"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "12"
  }
}
