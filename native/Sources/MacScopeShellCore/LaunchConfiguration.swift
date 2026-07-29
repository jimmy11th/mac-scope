import Foundation

public struct LaunchConfiguration: Equatable {
  public let executableURL: URL
  public let arguments: [String]
  public let currentDirectoryURL: URL
  public let environment: [String]

  public static func resolve(
    environment sourceEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    bundleInfo: [String: Any] = Bundle.main.infoDictionary ?? [:],
    bundleURL: URL = Bundle.main.bundleURL,
    currentDirectoryURL: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    ),
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) throws -> LaunchConfiguration {
    let childEnvironment = makeChildEnvironment(
      sourceEnvironment,
      homeDirectoryURL: homeDirectoryURL
    )

    if let overridePath = nonempty(sourceEnvironment["MACSCOPE_EXECUTABLE"]) {
      let executableURL = URL(fileURLWithPath: overridePath)
      guard fileManager.isExecutableFile(atPath: executableURL.path) else {
        throw LaunchConfigurationError.executableUnavailable(executableURL.path)
      }
      let arguments = try decodeArguments(sourceEnvironment["MACSCOPE_ARGUMENTS_JSON"])
      let workingDirectory =
        nonempty(sourceEnvironment["MACSCOPE_WORKING_DIRECTORY"])
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? currentDirectoryURL
      return LaunchConfiguration(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: workingDirectory,
        environment: childEnvironment
      )
    }

    let bundledExecutable =
      bundleURL
      .appendingPathComponent("Contents", isDirectory: true)
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("macscope")
    if fileManager.isExecutableFile(atPath: bundledExecutable.path) {
      return LaunchConfiguration(
        executableURL: bundledExecutable,
        arguments: [],
        currentDirectoryURL: bundledExecutable.deletingLastPathComponent(),
        environment: childEnvironment
      )
    }

    let projectRoot = try resolveProjectRoot(
      environment: sourceEnvironment,
      bundleInfo: bundleInfo,
      currentDirectoryURL: currentDirectoryURL,
      fileManager: fileManager
    )
    let uvURL = try resolveUVExecutable(
      environment: sourceEnvironment,
      bundleInfo: bundleInfo,
      homeDirectoryURL: homeDirectoryURL,
      fileManager: fileManager
    )
    return LaunchConfiguration(
      executableURL: uvURL,
      arguments: ["run", "--project", projectRoot.path, "macscope"],
      currentDirectoryURL: projectRoot,
      environment: childEnvironment
    )
  }

  private static func resolveProjectRoot(
    environment: [String: String],
    bundleInfo: [String: Any],
    currentDirectoryURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    let explicitCandidates = [
      nonempty(environment["MACSCOPE_PROJECT_ROOT"]),
      nonempty(bundleInfo["MacScopeProjectRoot"] as? String),
    ].compactMap { $0 }
    for path in explicitCandidates {
      let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
      if isProjectRoot(candidate, fileManager: fileManager) {
        return candidate
      }
    }

    var candidate = currentDirectoryURL.standardizedFileURL
    while candidate.path != "/" {
      if isProjectRoot(candidate, fileManager: fileManager) {
        return candidate
      }
      candidate.deleteLastPathComponent()
    }
    throw LaunchConfigurationError.projectRootUnavailable
  }

  private static func resolveUVExecutable(
    environment: [String: String],
    bundleInfo: [String: Any],
    homeDirectoryURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    let candidates = [
      nonempty(environment["MACSCOPE_UV_PATH"]),
      nonempty(bundleInfo["MacScopeUVPath"] as? String),
      homeDirectoryURL.appendingPathComponent(".local/bin/uv").path,
      "/opt/homebrew/bin/uv",
      "/usr/local/bin/uv",
    ].compactMap { $0 }
    for path in candidates {
      if fileManager.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
      }
    }
    throw LaunchConfigurationError.uvUnavailable
  }

  private static func makeChildEnvironment(
    _ source: [String: String],
    homeDirectoryURL: URL
  ) -> [String] {
    var environment = source
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["PYTHONUNBUFFERED"] = "1"
    environment["MACSCOPE_NATIVE_SHELL"] = "1"
    environment["MACSCOPE_HOST_PID"] = String(ProcessInfo.processInfo.processIdentifier)

    let preferredPaths = [
      homeDirectoryURL.appendingPathComponent(".local/bin").path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    let inheritedPaths = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    environment["PATH"] = unique(preferredPaths + inheritedPaths).joined(separator: ":")
    return environment.keys.sorted().compactMap { key in
      environment[key].map { "\(key)=\($0)" }
    }
  }

  private static func decodeArguments(_ value: String?) throws -> [String] {
    guard let value = nonempty(value) else {
      return []
    }
    guard let data = value.data(using: .utf8) else {
      throw LaunchConfigurationError.invalidArguments
    }
    do {
      return try JSONDecoder().decode([String].self, from: data)
    } catch {
      throw LaunchConfigurationError.invalidArguments
    }
  }

  private static func isProjectRoot(_ url: URL, fileManager: FileManager) -> Bool {
    fileManager.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path)
      && fileManager.fileExists(
        atPath: url.appendingPathComponent("src/macscope", isDirectory: true).path
      )
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return value
  }

  private static func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }
}

public enum LaunchConfigurationError: LocalizedError {
  case executableUnavailable(String)
  case invalidArguments
  case projectRootUnavailable
  case uvUnavailable

  public var errorDescription: String? {
    switch self {
    case .executableUnavailable(let path):
      "MacScope executable is unavailable at \(path)."
    case .invalidArguments:
      "MACSCOPE_ARGUMENTS_JSON must contain a JSON array of strings."
    case .projectRootUnavailable:
      "The MacScope project directory could not be located."
    case .uvUnavailable:
      "The uv executable could not be located."
    }
  }
}
