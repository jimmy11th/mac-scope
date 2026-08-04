import Foundation

enum DeveloperCommand: Codable, Equatable, Sendable {
  case arguments([String])
  case shell(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let values = try? container.decode([String].self), !values.isEmpty {
      self = .arguments(values)
    } else {
      let value = try container.decode(String.self)
      guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Empty command")
      }
      self = .shell(value)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .arguments(let values): try container.encode(values)
    case .shell(let value): try container.encode(value)
    }
  }

  var displayValue: String {
    switch self {
    case .arguments(let values): values.joined(separator: " ")
    case .shell(let value): value
    }
  }
}

struct DeveloperServiceDefinition: Codable, Identifiable, Equatable, Sendable {
  var id: String
  var name: String?
  var cwd: String?
  var command: DeveloperCommand?
  var build: DeveloperCommand?
  var buildFilter: String?
  var port: Int?
  var readyPattern: String?
  var selected: Bool?
  var rank: Int?
  var isHost: Bool?
  var env: [String: String]?

  var displayName: String { name?.isEmpty == false ? name! : id }
}

struct DeveloperServiceDefaults: Codable, Equatable, Sendable {
  var startCommand: DeveloperCommand?
  var readyPattern: String?
}

struct DeveloperBuildAll: Codable, Equatable, Sendable {
  var command: DeveloperCommand?
}

struct DeveloperServiceProfile: Codable, Identifiable, Equatable, Sendable {
  var version: Int?
  var id: String
  var name: String
  var root: String
  var readyPattern: String?
  var defaults: DeveloperServiceDefaults?
  var buildAll: DeveloperBuildAll?
  var services: [DeveloperServiceDefinition]

  var defaultStartCommand: DeveloperCommand {
    defaults?.startCommand ?? .arguments(["pnpm", "run", "dev"])
  }

  var defaultReadyPattern: String? {
    defaults?.readyPattern ?? readyPattern
  }
}

enum DeveloperServiceState: String, Sendable {
  case running
  case starting
  case compileFailed
  case external
  case stopped
}

enum DeveloperCompileState: String, Sendable {
  case compiled
  case compiling
  case failed
  case notRequired
  case notRunning
}

struct DeveloperServiceRuntime: Identifiable, Sendable {
  var definition: DeveloperServiceDefinition
  var state: DeveloperServiceState
  var compileState: DeveloperCompileState
  var pid: Int32?
  var portListening: Bool
  var logPath: String
  var resolvedWorkingDirectory: String

  var id: String { definition.id }
}

struct DeveloperGitStatus: Sendable {
  var branch = "-"
  var upstream = ""
  var dirtyCount = 0
  var ahead = 0
  var behind = 0

  var summary: String {
    var parts = [branch]
    if dirtyCount > 0 { parts.append("\(dirtyCount) changed") }
    if ahead > 0 { parts.append("↑\(ahead)") }
    if behind > 0 { parts.append("↓\(behind)") }
    return parts.joined(separator: " · ")
  }
}

struct DeveloperCommandResult: Sendable {
  var title: String
  var succeeded: Bool
  var output: String
}

enum DeveloperServicesError: LocalizedError, Sendable {
  case profileUnavailable(String)
  case invalidProfile(String)
  case externalProcess(String)
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .profileUnavailable(let detail), .invalidProfile(let detail),
      .externalProcess(let detail), .commandFailed(let detail): detail
    }
  }
}
