import Combine
import Darwin
import Foundation

enum PortTransport: String, CaseIterable, Identifiable, Sendable {
  case tcp = "TCP"
  case udp = "UDP"

  var id: String { rawValue }
}

enum PortScope: String, Sendable {
  case local
  case allInterfaces
  case specific
}

struct PortRecord: Identifiable, Hashable, Sendable {
  let pid: Int32
  let processName: String
  let executablePath: String
  let software: SoftwareIdentity
  let transport: PortTransport
  let address: String
  let port: Int
  let scope: PortScope

  var id: String {
    "\(transport.rawValue):\(address):\(port):\(pid)"
  }
}

actor PortInfoService {
  private var classifier = ProcessClassifier()

  func listeningPorts() throws -> [PortRecord] {
    let tcp = try commandOutput(arguments: [
      "-nP", "-iTCP", "-sTCP:LISTEN", "-FpcnPT",
    ])
    let udp = try commandOutput(arguments: [
      "-nP", "-iUDP", "-FpcnP",
    ])
    let parsed = parse(tcp, expectedTransport: .tcp) + parse(udp, expectedTransport: .udp)
    var ids = Set<PortRecord.ID>()
    return parsed
      .filter { ids.insert($0.id).inserted }
      .sorted { lhs, rhs in
        if lhs.port != rhs.port { return lhs.port < rhs.port }
        if lhs.transport != rhs.transport { return lhs.transport.rawValue < rhs.transport.rawValue }
        return lhs.pid < rhs.pid
      }
  }

  private func commandOutput(arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = arguments
    process.environment = [
      "LC_ALL": "en_US.UTF-8",
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    process.standardOutput = output
    process.standardError = error
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorData = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 || (process.terminationStatus == 1 && !data.isEmpty) else {
      let detail = String(data: errorData, encoding: .utf8) ?? "lsof failed"
      throw PortInfoError.commandFailed(detail)
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  private func parse(_ output: String, expectedTransport: PortTransport) -> [PortRecord] {
    var records: [PortRecord] = []
    var pid: Int32?
    var command = ""
    var transport = expectedTransport

    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let prefix = line.first else { continue }
      let value = String(line.dropFirst())
      switch prefix {
      case "p":
        pid = Int32(value)
        command = ""
        transport = expectedTransport
      case "c":
        command = value
      case "P":
        transport = PortTransport(rawValue: value) ?? expectedTransport
      case "n":
        guard
          let pid,
          let endpoint = endpoint(from: value),
          endpoint.port > 0
        else { continue }
        let executablePath = readExecutablePath(pid: pid) ?? command
        let software = classifier.software(executablePath: executablePath, command: command)
        records.append(
          PortRecord(
            pid: pid,
            processName: command.isEmpty ? URL(fileURLWithPath: executablePath).lastPathComponent : command,
            executablePath: executablePath,
            software: software,
            transport: transport,
            address: endpoint.address,
            port: endpoint.port,
            scope: scope(for: endpoint.address)
          )
        )
      default:
        continue
      }
    }
    return records
  }

  private func endpoint(from value: String) -> (address: String, port: Int)? {
    if value.hasPrefix("[") {
      guard
        let closingBracket = value.firstIndex(of: "]"),
        value.index(after: closingBracket) < value.endIndex,
        value[value.index(after: closingBracket)] == ":",
        let port = Int(value[value.index(closingBracket, offsetBy: 2)...])
      else { return nil }
      return (String(value[value.index(after: value.startIndex)..<closingBracket]), port)
    }
    guard let separator = value.lastIndex(of: ":"), let port = Int(value[value.index(after: separator)...])
    else { return nil }
    return (String(value[..<separator]), port)
  }

  private func scope(for address: String) -> PortScope {
    let normalized = address.lowercased()
    if normalized == "127.0.0.1" || normalized == "::1" || normalized == "localhost" {
      return .local
    }
    if normalized == "*" || normalized == "0.0.0.0" || normalized == "::" {
      return .allInterfaces
    }
    return .specific
  }

  private func readExecutablePath(pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

@MainActor
final class PortInfoStore: ObservableObject {
  @Published private(set) var records: [PortRecord] = []
  @Published private(set) var isLoading = false
  @Published var errorMessage = ""

  private let service = PortInfoService()

  func refresh() {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = ""
    Task { [weak self, service] in
      do {
        let records = try await service.listeningPorts()
        guard !Task.isCancelled else { return }
        self?.records = records
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isLoading = false
    }
  }

  func send(signal: Int32, to record: PortRecord) {
    guard record.pid > 1, record.pid != ProcessInfo.processInfo.processIdentifier else {
      errorMessage = "This process is protected."
      return
    }
    guard Darwin.kill(record.pid, signal) == 0 else {
      errorMessage = String(cString: strerror(errno))
      return
    }
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      self?.refresh()
    }
  }
}

private enum PortInfoError: LocalizedError {
  case commandFailed(String)

  var errorDescription: String? {
    switch self {
    case .commandFailed(let detail): detail
    }
  }
}
