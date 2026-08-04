import Darwin
import Foundation
import Combine

actor MihomoService {
  private struct LegacySettings: Decodable {
    var binary: String?
    var config: String?
    var directDomains: [String]?
    var directDomain: String?
    var autoStart: Bool?
    var siteBindings: [MihomoSiteBinding]?
  }

  private let fileManager: FileManager
  private let stateDirectory: URL
  private let legacyStateDirectory: URL
  private var recoverySuspended = false
  private var lastRecoveryAttempt = Date.distantPast

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    stateDirectory = applicationSupport.appendingPathComponent("MacScope/mihomo", isDirectory: true)
    legacyStateDirectory = applicationSupport.appendingPathComponent(
      "warrior-local-services/mihomo",
      isDirectory: true
    )
  }

  func loadSettings() throws -> MihomoSettings {
    let settingsURL = stateDirectory.appendingPathComponent("settings.json")
    var settings: MihomoSettings
    if let data = try? Data(contentsOf: settingsURL),
      let decoded = try? JSONDecoder().decode(MihomoSettings.self, from: data)
    {
      settings = decoded
    } else if let migrated = try loadLegacySettings() {
      settings = migrated
      try saveSettings(migrated)
    } else {
      settings = .defaults
    }

    if settings.binaryPath.isEmpty {
      settings.binaryPath = discoverBinary() ?? ""
    }
    settings.configPath = NSString(string: settings.configPath).expandingTildeInPath
    settings.directDomains = try MihomoConfiguration.normalizeDomains(settings.directDomains)
    if settings.directDomains.isEmpty { settings.directDomains = MihomoSettings.defaults.directDomains }
    return settings
  }

  func saveSettings(_ proposed: MihomoSettings) throws {
    var settings = proposed
    settings.binaryPath = NSString(string: settings.binaryPath).expandingTildeInPath
    settings.configPath = NSString(string: settings.configPath).expandingTildeInPath
    settings.directDomains = try MihomoConfiguration.normalizeDomains(settings.directDomains)
    if settings.directDomains.isEmpty { settings.directDomains = MihomoSettings.defaults.directDomains }
    try createStateDirectory()
    let data = try JSONEncoder.pretty.encode(settings)
    try data.write(to: stateDirectory.appendingPathComponent("settings.json"), options: .atomic)
  }

  func validate(_ settings: MihomoSettings) throws -> String {
    guard !settings.binaryPath.isEmpty, fileManager.isExecutableFile(atPath: settings.binaryPath) else {
      throw MihomoError.invalidConfiguration("Choose an executable Mihomo binary.")
    }
    guard fileManager.isReadableFile(atPath: settings.configPath) else {
      throw MihomoError.invalidConfiguration("Choose a readable Mihomo YAML config.")
    }
    _ = try controllerConfiguration(for: settings)

    let process = Process()
    let output = Pipe()
    let error = Pipe()
    process.executableURL = URL(fileURLWithPath: settings.binaryPath)
    process.arguments = [
      "-t", "-d", URL(fileURLWithPath: settings.configPath).deletingLastPathComponent().path,
      "-f", settings.configPath,
    ]
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      throw MihomoError.commandFailed("Mihomo config check could not start: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    let stderr = error.fileHandleForReading.readDataToEndOfFile()
    let detail = String(data: stderr.isEmpty ? stdout : stderr, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      throw MihomoError.invalidConfiguration(
        detail.isEmpty ? "Mihomo rejected the configuration." : detail
      )
    }
    return detail.isEmpty ? "Configuration valid" : detail
  }

  func status() async throws -> MihomoStatus {
    let settings = try loadSettings()
    let pid = storedPID()
    let running = isManagedProcess(pid: pid, binaryPath: settings.binaryPath)
    if !running, pid > 0 { try? fileManager.removeItem(at: pidURL) }
    let usage = running ? processUsage(pid: pid) : (0, 0)
    return MihomoStatus(
      isRunning: running,
      pid: running ? pid : 0,
      currentNode: running ? (try? await currentNode(settings: settings)) ?? "-" : "-",
      cpuPercent: usage.0,
      memoryBytes: usage.1,
      logPath: logURL.path,
      lastError: (try? String(contentsOf: errorURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    )
  }

  func start() async throws -> MihomoStatus {
    let before = try await status()
    if before.isRunning { return before }
    let settings = try loadSettings()
    _ = try validate(settings)

    let original = try String(contentsOfFile: settings.configPath, encoding: .utf8)
    var updated = try MihomoConfiguration.addDirectRules(
      to: original,
      domains: settings.directDomains
    )
    updated = try MihomoConfiguration.applyingBindings(
      to: updated,
      bindings: settings.siteBindings,
      directDomains: settings.directDomains
    )
    if updated != original {
      try writeValidatedConfig(original: original, updated: updated, settings: settings)
    }

    try createStateDirectory()
    if !fileManager.fileExists(atPath: logURL.path) {
      fileManager.createFile(atPath: logURL.path, contents: nil)
    }
    let logHandle = try FileHandle(forWritingTo: logURL)
    try logHandle.seekToEnd()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: settings.binaryPath)
    process.arguments = [
      "-d", URL(fileURLWithPath: settings.configPath).deletingLastPathComponent().path,
      "-f", settings.configPath,
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle
    do {
      try process.run()
    } catch {
      try? logHandle.close()
      try record(error)
      throw MihomoError.commandFailed("Mihomo could not start: \(error.localizedDescription)")
    }
    let pid = process.processIdentifier
    try Data("\(pid)\n".utf8).write(to: pidURL, options: .atomic)
    try? logHandle.close()
    try await Task.sleep(nanoseconds: 300_000_000)
    let after = try await status()
    guard after.isRunning else {
      let failure = MihomoError.commandFailed("Mihomo exited during startup. Inspect \(logURL.path).")
      try record(failure)
      throw failure
    }
    try clearError()
    recoverySuspended = false
    return after
  }

  func stop() async throws -> MihomoStatus {
    let settings = try loadSettings()
    let pid = storedPID()
    if isManagedProcess(pid: pid, binaryPath: settings.binaryPath) {
      Darwin.kill(pid, SIGTERM)
      for _ in 0..<20 where isManagedProcess(pid: pid, binaryPath: settings.binaryPath) {
        try await Task.sleep(nanoseconds: 100_000_000)
      }
    }
    guard !isManagedProcess(pid: pid, binaryPath: settings.binaryPath) else {
      throw MihomoError.commandFailed("Mihomo did not stop after SIGTERM; its PID record was preserved.")
    }
    try? fileManager.removeItem(at: pidURL)
    recoverySuspended = true
    return try await status()
  }

  func reconcileAtLaunch() async throws -> MihomoStatus {
    let settings = try loadSettings()
    recoverySuspended = false
    if settings.autoStart {
      lastRecoveryAttempt = Date()
      return try await start()
    }
    return try await status()
  }

  func reconcileAfterUnexpectedExit() async throws -> MihomoStatus {
    let settings = try loadSettings()
    let current = try await status()
    guard settings.autoStart, !current.isRunning, !recoverySuspended else { return current }
    guard Date().timeIntervalSince(lastRecoveryAttempt) >= 60 else { return current }
    lastRecoveryAttempt = Date()
    return try await start()
  }

  func proxyCatalog() async throws -> MihomoProxyCatalog {
    let settings = try loadSettings()
    let response: MihomoProxyResponse = try await apiRequest(settings: settings, path: "/proxies")
    let excludedTypes = Set(["reject", "compatible", "pass"])
    var groups: [MihomoProxyGroup] = []
    var nodes: [MihomoProxyNode] = []
    for (key, entry) in response.proxies {
      let name = entry.name ?? key
      if let members = entry.all {
        groups.append(
          MihomoProxyGroup(
            name: name,
            type: entry.type ?? "Group",
            current: entry.now ?? entry.fixed ?? "",
            members: members
          )
        )
      } else if !excludedTypes.contains((entry.type ?? "").lowercased()) {
        nodes.append(
          MihomoProxyNode(
            name: name,
            type: entry.type ?? "Proxy",
            isAlive: entry.alive != false,
            provider: entry.provider ?? ""
          )
        )
      }
    }
    groups.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return MihomoProxyCatalog(groups: groups, nodes: nodes, entries: response.proxies)
  }

  func selectProxy(group: String, node: String) async throws {
    let settings = try loadSettings()
    let catalog = try await proxyCatalog()
    guard let selectedGroup = catalog.groups.first(where: { $0.name == group }) else {
      throw MihomoError.apiFailed("Unknown policy group: \(group)")
    }
    guard selectedGroup.members.contains(node) else {
      throw MihomoError.apiFailed("\(node) is not a member of \(group).")
    }
    let body = try JSONSerialization.data(withJSONObject: ["name": node])
    try await apiRequestWithoutResponse(
      settings: settings,
      path: "/proxies/\(Self.urlPathComponent(group))",
      method: "PUT",
      body: body
    )
  }

  func saveBinding(_ binding: MihomoSiteBinding) async throws {
    var settings = try loadSettings()
    let normalizedDomain = try MihomoConfiguration.normalizeDomains([binding.domain])
    guard let domain = normalizedDomain.first else {
      throw MihomoError.invalidBinding("A site binding requires a domain.")
    }
    let catalog = try await proxyCatalog()
    guard catalog.entries[binding.outbound] != nil else {
      throw MihomoError.invalidBinding("Unknown node or policy group: \(binding.outbound)")
    }
    let item = MihomoSiteBinding(domain: domain, outbound: binding.outbound)
    settings.siteBindings.removeAll { $0.domain == domain }
    settings.siteBindings.append(item)
    try await writeBindings(settings)
  }

  func removeBinding(domain: String) async throws {
    var settings = try loadSettings()
    guard let domain = try MihomoConfiguration.normalizeDomains([domain]).first else { return }
    settings.siteBindings.removeAll { $0.domain == domain }
    try await writeBindings(settings)
  }

  func restoreBackup() async throws {
    let settings = try loadSettings()
    let config = URL(fileURLWithPath: settings.configPath)
    let currentBackup = URL(fileURLWithPath: settings.configPath + ".macscope.bak")
    let legacyBackup = URL(fileURLWithPath: settings.configPath + ".warrior.bak")
    let backup = fileManager.fileExists(atPath: currentBackup.path) ? currentBackup : legacyBackup
    guard fileManager.fileExists(atPath: backup.path) else {
      throw MihomoError.invalidConfiguration("No MacScope or legacy Warrior backup exists.")
    }
    let originalData = try Data(contentsOf: config)
    let backupData = try Data(contentsOf: backup)
    let wasRunning = (try await status()).isRunning
    do {
      try backupData.write(to: config, options: .atomic)
      _ = try validate(settings)
      if wasRunning { try await reload(settings: settings) }
    } catch {
      try? originalData.write(to: config, options: .atomic)
      if wasRunning { try? await reload(settings: settings) }
      throw error
    }
  }

  func probe(
    url: URL,
    expectedStatus: String = "200-399",
    timeoutMilliseconds: Int = 5_000,
    repeats: Int = 3,
    group: String? = nil
  ) async throws -> MihomoProbeReport {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil
    else { throw MihomoError.apiFailed("The test URL must use HTTP(S) and contain no credentials.") }
    guard (500...30_000).contains(timeoutMilliseconds), (1...10).contains(repeats) else {
      throw MihomoError.apiFailed("Timeout must be 500–30000 ms and repeats must be 1–10.")
    }
    guard expectedStatus == "*" || expectedStatus.range(
      of: #"^(?:\d{3}(?:-\d{3})?)(?:/\d{3}(?:-\d{3})?)*$"#,
      options: .regularExpression
    ) != nil else {
      throw MihomoError.apiFailed("Expected status must look like 200-399 or 200/204.")
    }
    let settings = try loadSettings()
    let catalog = try await proxyCatalog()
    let names: [String]
    if let group, !group.isEmpty {
      names = flattenedMembers(of: group, entries: catalog.entries)
    } else {
      names = catalog.nodes.map(\.name)
    }
    guard !names.isEmpty else { throw MihomoError.apiFailed("No testable nodes were found.") }

    var results: [MihomoProbeResult] = []
    for batch in names.chunked(size: 6) {
      let batchResults = try await withThrowingTaskGroup(of: MihomoProbeResult.self) { taskGroup in
        for name in batch {
          taskGroup.addTask {
            var delays: [Int] = []
            for _ in 0..<repeats {
              var components = URLComponents()
              components.queryItems = [
                URLQueryItem(name: "url", value: url.absoluteString),
                URLQueryItem(name: "timeout", value: String(timeoutMilliseconds)),
              ]
              if expectedStatus != "*" {
                components.queryItems?.append(URLQueryItem(name: "expected", value: expectedStatus))
              }
              let path = "/proxies/\(Self.urlPathComponent(name))/delay?\(components.percentEncodedQuery ?? "")"
              if let response: MihomoDelayResponse = try? await self.apiRequest(
                settings: settings,
                path: path,
                timeout: Double(timeoutMilliseconds) / 1_000 + 1.5
              ), let delay = response.delay {
                delays.append(delay)
              }
            }
            delays.sort()
            let nodeType = catalog.nodes.first(where: { $0.name == name })?.type ?? "Proxy"
            return MihomoProbeResult(
              name: name,
              type: nodeType,
              successes: delays.count,
              attempts: repeats,
              medianMilliseconds: delays.isEmpty ? 0 : delays[delays.count / 2],
              p95Milliseconds: delays.isEmpty ? 0 : delays[Int(ceil(Double(delays.count) * 0.95)) - 1]
            )
          }
        }
        var values: [MihomoProbeResult] = []
        for try await value in taskGroup { values.append(value) }
        return values
      }
      results.append(contentsOf: batchResults)
    }
    results.sort {
      if $0.successes != $1.successes { return $0.successes > $1.successes }
      if $0.medianMilliseconds == 0 { return false }
      if $1.medianMilliseconds == 0 { return true }
      return $0.medianMilliseconds < $1.medianMilliseconds
    }
    let recommendation = results.first(where: { $0.successes == repeats })
      ?? results.first(where: { $0.successes > 0 })
    return MihomoProbeReport(url: url, results: results, recommendation: recommendation)
  }

  private func writeBindings(_ settings: MihomoSettings) async throws {
    let original = try String(contentsOfFile: settings.configPath, encoding: .utf8)
    let updated = try MihomoConfiguration.applyingBindings(
      to: original,
      bindings: settings.siteBindings,
      directDomains: settings.directDomains
    )
    guard updated != original else {
      try saveSettings(settings)
      return
    }
    let wasRunning = isManagedProcess(pid: storedPID(), binaryPath: settings.binaryPath)
    do {
      try writeValidatedConfig(original: original, updated: updated, settings: settings)
      if wasRunning { try await reload(settings: settings) }
      try saveSettings(settings)
      try clearError()
    } catch {
      try? Data(original.utf8).write(
        to: URL(fileURLWithPath: settings.configPath),
        options: .atomic
      )
      if wasRunning { try? await reload(settings: settings) }
      try? record(error)
      throw error
    }
  }

  private func writeValidatedConfig(
    original: String,
    updated: String,
    settings: MihomoSettings
  ) throws {
    guard original != updated else { return }
    let config = URL(fileURLWithPath: settings.configPath)
    let backup = URL(fileURLWithPath: settings.configPath + ".macscope.bak")
    try Data(original.utf8).write(to: backup, options: .atomic)
    do {
      try Data(updated.utf8).write(to: config, options: .atomic)
      _ = try validate(settings)
    } catch {
      try? Data(original.utf8).write(to: config, options: .atomic)
      throw error
    }
  }

  private func reload(settings: MihomoSettings) async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "path": settings.configPath,
      "payload": "",
    ])
    try await apiRequestWithoutResponse(
      settings: settings,
      path: "/configs?force=true",
      method: "PUT",
      body: body,
      timeout: 15
    )
  }

  private func currentNode(settings: MihomoSettings) async throws -> String {
    let entry: MihomoProxyEntry = try await apiRequest(
      settings: settings,
      path: "/proxies/GLOBAL",
      timeout: 0.8
    )
    return entry.now ?? entry.fixed ?? "-"
  }

  private func controllerConfiguration(
    for settings: MihomoSettings
  ) throws -> MihomoControllerConfiguration {
    let source = try String(contentsOfFile: settings.configPath, encoding: .utf8)
    return try MihomoConfiguration.controller(from: source)
  }

  private func apiRequest<Response: Decodable & Sendable>(
    settings: MihomoSettings,
    path: String,
    timeout: TimeInterval = 10
  ) async throws -> Response {
    let data = try await apiData(settings: settings, path: path, timeout: timeout)
    do { return try JSONDecoder().decode(Response.self, from: data) }
    catch { throw MihomoError.apiFailed("Mihomo returned an unexpected response.") }
  }

  private func apiRequestWithoutResponse(
    settings: MihomoSettings,
    path: String,
    method: String,
    body: Data,
    timeout: TimeInterval = 10
  ) async throws {
    _ = try await apiData(
      settings: settings,
      path: path,
      method: method,
      body: body,
      timeout: timeout
    )
  }

  private func apiData(
    settings: MihomoSettings,
    path: String,
    method: String = "GET",
    body: Data? = nil,
    timeout: TimeInterval = 10
  ) async throws -> Data {
    let controller = try controllerConfiguration(for: settings)
    guard let url = URL(string: path, relativeTo: controller.baseURL)?.absoluteURL else {
      throw MihomoError.apiFailed("The Mihomo API URL is invalid.")
    }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if !controller.secret.isEmpty {
      request.setValue("Bearer \(controller.secret)", forHTTPHeaderField: "Authorization")
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let detail = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw MihomoError.apiFailed("Mihomo API \(status): \(detail.prefix(300))")
      }
      return data
    } catch let error as MihomoError {
      throw error
    } catch {
      throw MihomoError.apiFailed(error.localizedDescription)
    }
  }

  private func flattenedMembers(
    of name: String,
    entries: [String: MihomoProxyEntry],
    visited: Set<String> = []
  ) -> [String] {
    guard !visited.contains(name) else { return [] }
    var visited = visited
    visited.insert(name)
    guard let entry = entries[name] else { return [] }
    guard let members = entry.all else { return [name] }
    var result: [String] = []
    for member in members {
      let values = flattenedMembers(of: member, entries: entries, visited: visited)
      for value in values where !result.contains(value) { result.append(value) }
    }
    return result
  }

  private static func urlPathComponent(_ value: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func processUsage(pid: Int32) -> (Double, UInt64) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "%cpu=,rss=", "-p", String(pid)]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return (0, 0) }
    process.waitUntilExit()
    let fields = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
      .split(whereSeparator: \.isWhitespace)
    return (
      fields.first.flatMap { Double($0) } ?? 0,
      fields.dropFirst().first.flatMap { UInt64($0) }.map { $0 * 1_024 } ?? 0
    )
  }

  private func isManagedProcess(pid: Int32, binaryPath: String) -> Bool {
    guard pid > 1, Darwin.kill(pid, 0) == 0, !binaryPath.isEmpty else { return false }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return false }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    let actual = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self))
      .resolvingSymlinksInPath().standardizedFileURL.path
    let expected = URL(fileURLWithPath: binaryPath)
      .resolvingSymlinksInPath().standardizedFileURL.path
    return actual == expected
  }

  private func storedPID() -> Int32 {
    guard let value = try? String(contentsOf: pidURL, encoding: .utf8) else { return 0 }
    return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  private func discoverBinary() -> String? {
    let candidates = [
      ProcessInfo.processInfo.environment["MIHOMO_BINARY"],
      "/opt/homebrew/bin/mihomo",
      "/usr/local/bin/mihomo",
      "/usr/bin/mihomo",
    ].compactMap { $0 }
    return candidates.first(where: { fileManager.isExecutableFile(atPath: $0) })
  }

  private func loadLegacySettings() throws -> MihomoSettings? {
    let url = legacyStateDirectory.appendingPathComponent("settings.json")
    guard let data = try? Data(contentsOf: url),
      let legacy = try? JSONDecoder().decode(LegacySettings.self, from: data)
    else { return nil }
    return MihomoSettings(
      binaryPath: legacy.binary ?? "",
      configPath: legacy.config ?? MihomoSettings.defaults.configPath,
      directDomains: legacy.directDomains
        ?? legacy.directDomain.map { [$0] }
        ?? MihomoSettings.defaults.directDomains,
      autoStart: legacy.autoStart ?? false,
      siteBindings: legacy.siteBindings ?? []
    )
  }

  private func createStateDirectory() throws {
    try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
  }

  private func record(_ error: Error) throws {
    try createStateDirectory()
    let detail = String(error.localizedDescription.prefix(1_000)) + "\n"
    try Data(detail.utf8).write(to: errorURL, options: .atomic)
  }

  private func clearError() throws {
    if fileManager.fileExists(atPath: errorURL.path) { try fileManager.removeItem(at: errorURL) }
  }

  private var pidURL: URL { stateDirectory.appendingPathComponent("mihomo.pid") }
  private var logURL: URL { stateDirectory.appendingPathComponent("mihomo.log") }
  private var errorURL: URL { stateDirectory.appendingPathComponent("last-error.txt") }
}

@MainActor
final class MihomoStore: ObservableObject {
  @Published private(set) var settings = MihomoSettings.defaults
  @Published private(set) var status = MihomoStatus()
  @Published private(set) var catalog = MihomoProxyCatalog.empty
  @Published private(set) var probeReport: MihomoProbeReport?
  @Published private(set) var isBusy = false
  @Published var errorMessage = ""
  @Published var operationMessage = ""

  private let service: MihomoService

  init(service: MihomoService = MihomoService()) {
    self.service = service
  }

  func reconcileAtLaunch() {
    perform("Mihomo status updated") { service in
      let status = try await service.reconcileAtLaunch()
      let settings = try await service.loadSettings()
      let catalog = status.isRunning ? (try? await service.proxyCatalog()) ?? .empty : .empty
      return (settings, status, catalog)
    }
  }

  func refresh() {
    guard !isBusy else { return }
    Task { [weak self, service] in
      do {
        let settings = try await service.loadSettings()
        let status = try await service.status()
        let catalog = status.isRunning ? (try? await service.proxyCatalog()) ?? .empty : .empty
        self?.settings = settings
        self?.status = status
        self?.catalog = catalog
        self?.errorMessage = ""
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func recoverIfNeeded() {
    guard !isBusy else { return }
    Task { [weak self, service] in
      do {
        let before = self?.status
        let status = try await service.reconcileAfterUnexpectedExit()
        guard before?.isRunning != status.isRunning else { return }
        self?.settings = try await service.loadSettings()
        self?.status = status
        self?.catalog = status.isRunning ? (try? await service.proxyCatalog()) ?? .empty : .empty
        if status.isRunning { self?.operationMessage = "Mihomo recovered after an unexpected exit" }
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func configure(_ settings: MihomoSettings) {
    perform("Configuration saved") { service in
      _ = try await service.validate(settings)
      try await service.saveSettings(settings)
      let status = try await service.status()
      let catalog = status.isRunning ? (try? await service.proxyCatalog()) ?? .empty : .empty
      return (try await service.loadSettings(), status, catalog)
    }
  }

  func start() {
    perform("Mihomo started") { service in
      let status = try await service.start()
      return (
        try await service.loadSettings(),
        status,
        (try? await service.proxyCatalog()) ?? .empty
      )
    }
  }

  func stop() {
    perform("Mihomo stopped") { service in
      (try await service.loadSettings(), try await service.stop(), .empty)
    }
  }

  func selectProxy(group: String, node: String) {
    perform("Switched \(group) to \(node)") { service in
      try await service.selectProxy(group: group, node: node)
      return (
        try await service.loadSettings(),
        try await service.status(),
        try await service.proxyCatalog()
      )
    }
  }

  func saveBinding(domain: String, outbound: String) {
    perform("Site route saved") { service in
      try await service.saveBinding(MihomoSiteBinding(domain: domain, outbound: outbound))
      return (
        try await service.loadSettings(),
        try await service.status(),
        try await service.proxyCatalog()
      )
    }
  }

  func removeBinding(domain: String) {
    perform("Site route removed") { service in
      try await service.removeBinding(domain: domain)
      return (
        try await service.loadSettings(),
        try await service.status(),
        try await service.proxyCatalog()
      )
    }
  }

  func restoreBackup() {
    perform("Configuration backup restored") { service in
      try await service.restoreBackup()
      let status = try await service.status()
      return (
        try await service.loadSettings(),
        status,
        status.isRunning ? try await service.proxyCatalog() : .empty
      )
    }
  }

  func probe(url: URL, repeats: Int, group: String?) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = ""
    operationMessage = "Testing nodes…"
    Task { [weak self, service] in
      do {
        let report = try await service.probe(url: url, repeats: repeats, group: group)
        self?.probeReport = report
        self?.operationMessage = report.recommendation.map {
          "Recommended: \($0.name) · \($0.medianMilliseconds) ms"
        } ?? "No reachable node"
      } catch {
        self?.errorMessage = error.localizedDescription
        self?.operationMessage = ""
      }
      self?.isBusy = false
    }
  }

  private func perform(
    _ successMessage: String,
    operation: @escaping @Sendable (MihomoService) async throws -> (
      MihomoSettings, MihomoStatus, MihomoProxyCatalog
    )
  ) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = ""
    operationMessage = "Working…"
    Task { [weak self, service] in
      do {
        let result = try await operation(service)
        self?.settings = result.0
        self?.status = result.1
        self?.catalog = result.2
        self?.operationMessage = successMessage
      } catch {
        self?.errorMessage = error.localizedDescription
        self?.operationMessage = ""
      }
      self?.isBusy = false
    }
  }
}

private extension JSONEncoder {
  static var pretty: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }
}

private extension Array {
  func chunked(size: Int) -> [[Element]] {
    guard size > 0 else { return [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, count)])
    }
  }
}
