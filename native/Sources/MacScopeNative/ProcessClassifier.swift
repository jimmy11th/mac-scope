import Foundation

struct ProcessClassifier {
  private static let systemRoots = [
    "/System",
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/libexec",
    "/Library/Apple/System",
  ]

  private static let installedSoftwareRoots = [
    "/Applications",
    "/Library/Application Support",
    "/Library/Frameworks",
    "/Library/PrivilegedHelperTools",
    "/Library/SystemExtensions",
  ]

  private static let userToolRoots = [
    "/opt",
    "/usr/local",
    "/nix",
  ]

  private let homePath: String
  private var cache: [String: SoftwareIdentity] = [:]

  init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    homePath = homeDirectory.standardizedFileURL.path
  }

  mutating func software(executablePath: String, command: String) -> SoftwareIdentity {
    let normalizedPath = Self.normalizedPath(executablePath)
    let cacheKey = normalizedPath ?? "command:\(command)"
    if let cached = cache[cacheKey] { return cached }

    let identity = Self.classify(
      normalizedPath: normalizedPath,
      command: command,
      homePath: homePath
    )
    if cache.count >= 2_048 {
      cache.removeAll(keepingCapacity: true)
    }
    cache[cacheKey] = identity
    return identity
  }

  static func classify(
    executablePath: String,
    command: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> SoftwareIdentity {
    classify(
      normalizedPath: normalizedPath(executablePath),
      command: command,
      homePath: homeDirectory.standardizedFileURL.path
    )
  }

  static func outermostApplicationURL(forExecutablePath executablePath: String) -> URL? {
    guard let path = normalizedPath(executablePath) else { return nil }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in URL(fileURLWithPath: path).pathComponents.dropFirst() {
      current.appendPathComponent(component)
      if component.lowercased().hasSuffix(".app") {
        return current.standardizedFileURL
      }
    }
    return nil
  }

  private static func classify(
    normalizedPath: String?,
    command: String,
    homePath: String
  ) -> SoftwareIdentity {
    guard let path = normalizedPath else {
      let name = displayName(forPath: nil, command: command)
      return SoftwareIdentity(
        id: "unknown:\(name.lowercased())",
        name: name,
        bundleIdentifier: nil,
        bundleURL: nil,
        origin: .unknown
      )
    }

    if let applicationURL = outermostApplicationURL(forExecutablePath: path) {
      let bundle = Bundle(url: applicationURL)
      let bundleIdentifier = bundle?.bundleIdentifier
      let name =
        bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? applicationURL.deletingPathExtension().lastPathComponent
      let origin: ProcessOrigin = isSystemPath(applicationURL.path)
        ? .macOSSystem : .installedSoftware
      return SoftwareIdentity(
        id: "application:\(applicationURL.path)",
        name: name,
        bundleIdentifier: bundleIdentifier,
        bundleURL: applicationURL,
        origin: origin
      )
    }

    let origin: ProcessOrigin
    if isSystemPath(path) {
      origin = .macOSSystem
    } else if isWithin(path, root: homePath) || userToolRoots.contains(where: {
      isWithin(path, root: $0)
    }) {
      origin = .userTool
    } else if installedSoftwareRoots.contains(where: { isWithin(path, root: $0) })
      || (isWithin(path, root: "/Library") && !isWithin(path, root: "/Library/Apple/System"))
    {
      origin = .installedSoftware
    } else {
      origin = .unknown
    }

    return SoftwareIdentity(
      id: "executable:\(path)",
      name: displayName(forPath: path, command: command),
      bundleIdentifier: nil,
      bundleURL: nil,
      origin: origin
    )
  }

  private static func normalizedPath(_ value: String) -> String? {
    guard value.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: value).standardizedFileURL.path
  }

  private static func displayName(forPath path: String?, command: String) -> String {
    if let path {
      let name = URL(fileURLWithPath: path).lastPathComponent
      if !name.isEmpty { return name }
    }
    let commandName = URL(fileURLWithPath: command).lastPathComponent
    return commandName.isEmpty ? command : commandName
  }

  private static func isSystemPath(_ path: String) -> Bool {
    let classificationPath: String
    let dataVolumePrefix = "/System/Volumes/Data"
    if path == dataVolumePrefix {
      classificationPath = "/"
    } else if path.hasPrefix(dataVolumePrefix + "/") {
      classificationPath = String(path.dropFirst(dataVolumePrefix.count))
    } else {
      classificationPath = path
    }
    return systemRoots.contains { isWithin(classificationPath, root: $0) }
  }

  private static func isWithin(_ path: String, root: String) -> Bool {
    path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
  }
}
