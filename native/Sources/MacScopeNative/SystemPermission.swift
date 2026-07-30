import AppKit
import Foundation

enum SystemPermission {
  @MainActor
  static func openFullDiskAccessSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  static func moveToTrashWithAdministratorAuthorization(_ source: URL) -> Result<Void, Error> {
    let fileManager = FileManager.default
    let trash = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
      ".Trash",
      isDirectory: true
    )
    var destination = trash.appendingPathComponent(source.lastPathComponent)
    var suffix = 2
    while fileManager.fileExists(atPath: destination.path) {
      let stem = source.deletingPathExtension().lastPathComponent
      let extensionName = source.pathExtension
      let candidate =
        extensionName.isEmpty
        ? "\(stem) \(suffix)"
        : "\(stem) \(suffix).\(extensionName)"
      destination = trash.appendingPathComponent(candidate)
      suffix += 1
    }

    let script = [
      "on run argv",
      "do shell script \"/bin/mv \" & quoted form of item 1 of argv & \" \" & quoted form of item 2 of argv with administrator privileges",
      "end run",
    ]
    let result = runAppleScript(script, arguments: [source.path, destination.path])
    return result.status == 0
      ? .success(())
      : .failure(PermissionError.operationFailed(result.message))
  }

  static func purgeFileCacheWithAdministratorAuthorization() -> Result<Void, Error> {
    let script = [
      "do shell script \"/usr/bin/purge\" with administrator privileges"
    ]
    let result = runAppleScript(script, arguments: [])
    return result.status == 0
      ? .success(())
      : .failure(PermissionError.operationFailed(result.message))
  }

  static func unregisterApplication(at url: URL) {
    let executable = URL(
      fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    )
    guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["-u", url.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  private static func runAppleScript(
    _ statements: [String],
    arguments: [String]
  ) -> (status: Int32, message: String) {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = statements.flatMap { ["-e", $0] } + arguments
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      return (1, error.localizedDescription)
    }
    let outputData = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let messageData = errorData.isEmpty ? outputData : errorData
    let message =
      String(data: messageData, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (process.terminationStatus, message)
  }
}

private enum PermissionError: LocalizedError {
  case operationFailed(String)

  var errorDescription: String? {
    switch self {
    case .operationFailed(let message):
      message.isEmpty ? "The authorized operation did not complete." : message
    }
  }
}
