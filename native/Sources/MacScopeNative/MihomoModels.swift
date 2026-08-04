import Foundation

struct MihomoSiteBinding: Codable, Hashable, Identifiable, Sendable {
  var domain: String
  var outbound: String

  var id: String { domain }
}

struct MihomoSettings: Codable, Equatable, Sendable {
  var binaryPath: String
  var configPath: String
  var directDomains: [String]
  var autoStart: Bool
  var siteBindings: [MihomoSiteBinding]

  static var defaults: MihomoSettings {
    MihomoSettings(
      binaryPath: "",
      configPath: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/mihomo/config.yaml").path,
      directDomains: ["tcb.cloud.tencent.com"],
      autoStart: false,
      siteBindings: []
    )
  }
}

struct MihomoStatus: Equatable, Sendable {
  var isRunning = false
  var pid: Int32 = 0
  var currentNode = "-"
  var cpuPercent = 0.0
  var memoryBytes: UInt64 = 0
  var logPath = ""
  var lastError = ""
}

struct MihomoProxyNode: Codable, Hashable, Identifiable, Sendable {
  var name: String
  var type: String
  var isAlive: Bool
  var provider: String

  var id: String { name }
}

struct MihomoProxyGroup: Codable, Hashable, Identifiable, Sendable {
  var name: String
  var type: String
  var current: String
  var members: [String]

  var id: String { name }
}

struct MihomoProxyCatalog: Sendable {
  var groups: [MihomoProxyGroup]
  var nodes: [MihomoProxyNode]
  var entries: [String: MihomoProxyEntry]

  static let empty = MihomoProxyCatalog(groups: [], nodes: [], entries: [:])
}

struct MihomoProxyEntry: Decodable, Sendable {
  var name: String?
  var type: String?
  var now: String?
  var fixed: String?
  var all: [String]?
  var alive: Bool?
  var provider: String?

  private enum CodingKeys: String, CodingKey {
    case name, type, now, fixed, all, alive
    case provider = "provider-name"
  }
}

struct MihomoProxyResponse: Decodable, Sendable {
  var proxies: [String: MihomoProxyEntry]
}

struct MihomoDelayResponse: Decodable, Sendable {
  var delay: Int?
}

struct MihomoProbeResult: Identifiable, Sendable {
  var name: String
  var type: String
  var successes: Int
  var attempts: Int
  var medianMilliseconds: Int
  var p95Milliseconds: Int

  var id: String { name }
}

struct MihomoProbeReport: Sendable {
  var url: URL
  var results: [MihomoProbeResult]
  var recommendation: MihomoProbeResult?
}

enum MihomoError: LocalizedError, Equatable, Sendable {
  case invalidDomain(String)
  case invalidController(String)
  case invalidConfiguration(String)
  case invalidBinding(String)
  case commandFailed(String)
  case apiFailed(String)
  case notRunning

  var errorDescription: String? {
    switch self {
    case .invalidDomain(let value): "Invalid domain: \(value)"
    case .invalidController(let detail): detail
    case .invalidConfiguration(let detail): detail
    case .invalidBinding(let detail): detail
    case .commandFailed(let detail): detail
    case .apiFailed(let detail): detail
    case .notRunning: "Mihomo is not running."
    }
  }
}
