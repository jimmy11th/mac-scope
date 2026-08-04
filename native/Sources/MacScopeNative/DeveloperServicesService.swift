import Darwin
import Foundation
import AppKit
import Combine

actor DeveloperServicesService {
  private struct AuthenticationResponse: Decodable {
    var token: String
  }
  private struct ProcessRecord: Codable {
    var id: String
    var pid: Int32
    var identity: String
    var startedAt: String?
  }

  private let fileManager: FileManager
  private let home: URL
  private var activeProcess: Process?

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    home = fileManager.homeDirectoryForCurrentUser
  }

  func loadActiveProfile() throws -> (DeveloperServiceProfile, URL) {
    let profiles = profilesDirectory
    let files = (try? fileManager.contentsOfDirectory(
      at: profiles,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
    guard !files.isEmpty else {
      throw DeveloperServicesError.profileUnavailable(
        "No Local Services profile was found in \(profiles.path)."
      )
    }
    let activeID = (try? String(contentsOf: activeProfileURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let selected = files.first { $0.deletingPathExtension().lastPathComponent == activeID } ?? files[0]
    let profile = try JSONDecoder().decode(
      DeveloperServiceProfile.self,
      from: Data(contentsOf: selected)
    )
    guard !profile.services.isEmpty else {
      throw DeveloperServicesError.invalidProfile("The active profile contains no services.")
    }
    return (profile, selected)
  }

  func listProfiles() throws -> [(DeveloperServiceProfile, URL, Bool)] {
    let activeID = (try? String(contentsOf: activeProfileURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return try fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { url in
        let profile = try JSONDecoder().decode(DeveloperServiceProfile.self, from: Data(contentsOf: url))
        return (profile, url, profile.id == activeID)
      }
  }

  func activateProfile(_ id: String) throws {
    let profile = try listProfiles().first { $0.0.id == id }
    guard profile != nil else { throw DeveloperServicesError.invalidProfile("Unknown profile: \(id)") }
    try fileManager.createDirectory(at: activeProfileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("\(id)\n".utf8).write(to: activeProfileURL, options: .atomic)
  }

  func updateProfileRoot(at profileURL: URL, root: String) throws {
    guard fileManager.fileExists(atPath: root) else {
      throw DeveloperServicesError.invalidProfile("The selected project folder does not exist.")
    }
    let data = try Data(contentsOf: profileURL)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DeveloperServicesError.invalidProfile("The active Profile is not a JSON object.")
    }
    object["root"] = root
    var updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    updated.append(0x0A)
    try updated.write(to: profileURL, options: .atomic)
  }

  func runtimes(profile: DeveloperServiceProfile) -> [DeveloperServiceRuntime] {
    profile.services.map { runtime(for: $0, profile: profile) }
  }

  func start(service: DeveloperServiceDefinition, profile: DeveloperServiceProfile) throws {
    let current = runtime(for: service, profile: profile)
    if current.state == .running || current.state == .starting { return }
    if current.state == .external {
      throw DeveloperServicesError.externalProcess(
        "\(service.id) is already active outside MacScope and will not be replaced."
      )
    }
    try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    let logURL = logURL(for: service.id)
    if !fileManager.fileExists(atPath: logURL.path) {
      fileManager.createFile(atPath: logURL.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: logURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("\n[macscope] starting \(service.id) at \(ISO8601DateFormatter().string(from: Date()))\n".utf8))

    let process = configuredProcess(
      command: service.command ?? profile.defaultStartCommand,
      workingDirectory: resolvedWorkingDirectory(service, profile: profile),
      environment: service.env ?? [:]
    )
    process.standardOutput = handle
    process.standardError = handle
    do { try process.run() }
    catch {
      try? handle.close()
      throw DeveloperServicesError.commandFailed(error.localizedDescription)
    }
    let pid = process.processIdentifier
    _ = Darwin.setpgid(pid, pid)
    guard let identity = processIdentity(pid) else {
      Darwin.kill(pid, SIGTERM)
      throw DeveloperServicesError.commandFailed("Could not verify the started process.")
    }
    let record = ProcessRecord(
      id: service.id,
      pid: pid,
      identity: identity,
      startedAt: ISO8601DateFormatter().string(from: Date())
    )
    try JSONEncoder.prettyDeveloper.encode(record).write(
      to: recordURL(for: service.id),
      options: .atomic
    )
    try? handle.close()
  }

  func stop(service: DeveloperServiceDefinition) async throws {
    guard let record = readRecord(service.id) else { return }
    guard isOwned(record) else {
      try? fileManager.removeItem(at: recordURL(for: service.id))
      return
    }
    terminateProcessTree(record.pid, signal: SIGTERM)
    for _ in 0..<30 where isOwned(record) {
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    if isOwned(record) { terminateProcessTree(record.pid, signal: SIGKILL) }
    if !isOwned(record) { try? fileManager.removeItem(at: recordURL(for: service.id)) }
  }

  func build(
    services: [DeveloperServiceDefinition],
    profile: DeveloperServiceProfile,
    force: Bool
  ) async throws -> DeveloperCommandResult {
    guard !services.isEmpty else {
      throw DeveloperServicesError.commandFailed("Select one or more services first.")
    }
    let filters = try services.map { service -> String in
      guard let filter = service.buildFilter, !filter.isEmpty else {
        throw DeveloperServicesError.invalidProfile("\(service.id) has no build filter.")
      }
      if service.id == "sim" || filter.hasPrefix("@warriortrading/remote-") { return filter }
      return filter.replacingOccurrences(of: "@warriortrading/", with: "@warriortrading/remote-")
    }
    let command = DeveloperCommand.arguments(
      ["pnpm", "turbo", "run", "build"]
        + filters.map { "--filter=\($0)" }
        + (force ? ["--force"] : [])
    )
    return try await runCommand(
      title: "Build \(services.count) services",
      command: command,
      workingDirectory: profile.root
    )
  }

  func buildAll(profile: DeveloperServiceProfile) async throws -> DeveloperCommandResult {
    try await runCommand(
      title: "Build all services",
      command: profile.buildAll?.command ?? .arguments(["pnpm", "build", "--concurrency=4"]),
      workingDirectory: profile.root
    )
  }

  func gitStatus(root: String) -> DeveloperGitStatus {
    let branch = try? quickCommand(["git", "-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"])
    let dirty = (try? quickCommand(["git", "-C", root, "status", "--porcelain=v1"])) ?? ""
    let upstream = (try? quickCommand([
      "git", "-C", root, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}",
    ])) ?? ""
    var ahead = 0
    var behind = 0
    if !upstream.isEmpty,
      let counts = try? quickCommand(["git", "-C", root, "rev-list", "--left-right", "--count", "HEAD...\(upstream)"])
    {
      let values = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
      if values.count == 2 { ahead = values[0]; behind = values[1] }
    }
    return DeveloperGitStatus(
      branch: branch?.isEmpty == false ? branch! : "detached",
      upstream: upstream,
      dirtyCount: dirty.split(separator: "\n").count,
      ahead: ahead,
      behind: behind
    )
  }

  func fetch(root: String) async throws -> DeveloperCommandResult {
    try await runCommand(
      title: "Git fetch",
      command: .arguments(["git", "fetch", "--prune"]),
      workingDirectory: root
    )
  }

  func pull(root: String) async throws -> DeveloperCommandResult {
    try await runCommand(
      title: "Git pull",
      command: .arguments(["git", "pull", "--ff-only"]),
      workingDirectory: root
    )
  }

  func authenticatedTestURL(email: String, password: String) async throws -> URL {
    guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
      throw DeveloperServicesError.commandFailed("Test login email and password are required.")
    }
    guard let endpoint = URL(
      string: "https://identity-dev.warriortrading.com/security/authentication/"
    ) else { throw DeveloperServicesError.commandFailed("The identity endpoint is invalid.") }
    var request = URLRequest(url: endpoint, timeoutInterval: 60)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "email": email,
      "password": password,
      "sourceType": 0,
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      throw DeveloperServicesError.commandFailed("Identity request failed with HTTP \(status).")
    }
    let token = try JSONDecoder().decode(AuthenticationResponse.self, from: data).token
    guard token.split(separator: ".").count == 3 else {
      throw DeveloperServicesError.commandFailed("The identity response did not contain a valid token.")
    }
    var components = URLComponents(string: "http://localhost:8080/sso")
    components?.queryItems = [URLQueryItem(name: "token", value: token)]
    guard let url = components?.url else {
      throw DeveloperServicesError.commandFailed("The local test URL could not be created.")
    }
    return url
  }

  func recentLog(serviceID: String, lines: Int = 500) -> String {
    guard let data = try? Data(contentsOf: logURL(for: serviceID)), !data.isEmpty else { return "" }
    let suffix = data.suffix(480 * 1_024)
    let text = String(decoding: suffix, as: UTF8.self)
    return text.components(separatedBy: .newlines).suffix(lines).joined(separator: "\n")
  }

  func cancel() {
    guard let process = activeProcess, process.isRunning else { return }
    terminateProcessTree(process.processIdentifier, signal: SIGTERM)
  }

  private func runtime(
    for service: DeveloperServiceDefinition,
    profile: DeveloperServiceProfile
  ) -> DeveloperServiceRuntime {
    let record = readRecord(service.id)
    let owned = record.map(isOwned) ?? false
    let listeningPID = service.port.flatMap(listeningProcess)
    let externalPID = listeningPID ?? (service.port == nil
      ? externalDevelopmentPID(workingDirectory: resolvedWorkingDirectory(service, profile: profile))
      : nil)
    let isListening = listeningPID != nil
    let compilation = compileState(service, profile: profile, isRunning: owned)
    let state: DeveloperServiceState
    if owned {
      state = compilation == .failed ? .compileFailed : .running
    } else if externalPID != nil {
      state = .external
    } else {
      state = .stopped
    }
    return DeveloperServiceRuntime(
      definition: service,
      state: state,
      compileState: compilation,
      pid: owned ? record?.pid : externalPID,
      portListening: isListening,
      logPath: logURL(for: service.id).path,
      resolvedWorkingDirectory: resolvedWorkingDirectory(service, profile: profile)
    )
  }

  private func compileState(
    _ service: DeveloperServiceDefinition,
    profile: DeveloperServiceProfile,
    isRunning: Bool
  ) -> DeveloperCompileState {
    let pattern = (service.readyPattern ?? profile.defaultReadyPattern)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard pattern?.isEmpty == false else { return .notRequired }
    guard isRunning else { return .notRunning }
    let log = recentLog(serviceID: service.id).lowercased()
    let success = log.range(of: pattern!.lowercased(), options: .backwards)?.lowerBound
    let failurePatterns = ["failed to compile", "compiled with errors", "compiled with 1 error"]
    let failure = failurePatterns.compactMap {
      log.range(of: $0, options: .backwards)?.lowerBound
    }.max()
    if let failure, success == nil || failure > success! { return .failed }
    return success == nil ? .compiling : .compiled
  }

  private func runCommand(
    title: String,
    command: DeveloperCommand,
    workingDirectory: String
  ) async throws -> DeveloperCommandResult {
    let process = configuredProcess(
      command: command,
      workingDirectory: workingDirectory,
      environment: [:]
    )
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    activeProcess = process
    do { try process.run() }
    catch {
      activeProcess = nil
      throw DeveloperServicesError.commandFailed(error.localizedDescription)
    }
    _ = Darwin.setpgid(process.processIdentifier, process.processIdentifier)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    activeProcess = nil
    let text = String(data: data, encoding: .utf8) ?? ""
    return DeveloperCommandResult(
      title: title,
      succeeded: process.terminationStatus == 0,
      output: text.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  private func configuredProcess(
    command: DeveloperCommand,
    workingDirectory: String,
    environment: [String: String]
  ) -> Process {
    let process = Process()
    switch command {
    case .arguments(let values):
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = values
    case .shell(let value):
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-lc", "exec \(value)"]
    }
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    var merged = ProcessInfo.processInfo.environment
    let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    let inheritedPath = merged["PATH"] ?? ""
    merged["PATH"] = inheritedPath.isEmpty ? standardPath : "\(standardPath):\(inheritedPath)"
    for (key, value) in environment { merged[key] = value }
    process.environment = merged
    return process
  }

  private func quickCommand(_ arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw DeveloperServicesError.commandFailed(arguments.joined(separator: " ")) }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func resolvedWorkingDirectory(
    _ service: DeveloperServiceDefinition,
    profile: DeveloperServiceProfile
  ) -> String {
    guard let cwd = service.cwd, !cwd.isEmpty else { return profile.root }
    let expanded = NSString(string: cwd).expandingTildeInPath
    if !NSString(string: expanded).isAbsolutePath {
      return URL(fileURLWithPath: profile.root, isDirectory: true).appendingPathComponent(cwd).path
    }
    let cwdURL = URL(fileURLWithPath: expanded)
    let oldRoot = URL(fileURLWithPath: profile.root, isDirectory: true).standardizedFileURL.path
    if cwdURL.standardizedFileURL.path.hasPrefix(oldRoot + "/") { return cwdURL.path }
    return cwdURL.path
  }

  private func listeningProcess(port: Int) -> Int32? {
    guard port > 0 else { return nil }
    let output = try? quickCommand([
      "/usr/sbin/lsof", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp",
    ])
    return output?.split(separator: "\n").first(where: { $0.hasPrefix("p") })
      .flatMap { Int32($0.dropFirst()) }
  }

  private func externalDevelopmentPID(workingDirectory: String) -> Int32? {
    guard let output = try? quickCommand([
      "/usr/sbin/lsof", "-nP", "-a", "-u", NSUserName(), "-d", "cwd", "-Fpn",
    ]) else { return nil }
    var pid: Int32?
    for line in output.split(separator: "\n") {
      if line.hasPrefix("p") { pid = Int32(line.dropFirst()) }
      guard line.hasPrefix("n"), String(line.dropFirst()) == workingDirectory, let pid else {
        continue
      }
      let command = (try? quickCommand(["/bin/ps", "-p", String(pid), "-o", "command="])) ?? ""
      if command.range(of: #"(?:pnpm|node|vite|turbo|webpack|next)"#, options: .regularExpression) != nil {
        return pid
      }
    }
    return nil
  }

  private func readRecord(_ id: String) -> ProcessRecord? {
    guard let data = try? Data(contentsOf: recordURL(for: id)) else { return nil }
    return try? JSONDecoder().decode(ProcessRecord.self, from: data)
  }

  private func isOwned(_ record: ProcessRecord) -> Bool {
    guard record.pid > 1, Darwin.kill(record.pid, 0) == 0 else { return false }
    return processIdentity(record.pid) == record.identity
  }

  private func processIdentity(_ pid: Int32) -> String? {
    guard let value = try? quickCommand(["/bin/ps", "-o", "lstart=", "-p", String(pid)]),
      !value.isEmpty
    else { return nil }
    return "ps:\(value)"
  }

  private func terminateProcessTree(_ pid: Int32, signal: Int32) {
    for child in descendantPIDs(of: pid).reversed() { Darwin.kill(child, signal) }
    Darwin.kill(pid, signal)
  }

  private func descendantPIDs(of pid: Int32) -> [Int32] {
    guard let output = try? quickCommand(["/usr/bin/pgrep", "-P", String(pid)]) else {
      return []
    }
    let direct = output.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
    return direct.flatMap { [$0] + descendantPIDs(of: $0) }
  }

  private func recordURL(for id: String) -> URL {
    stateDirectory.appendingPathComponent("\(id).json")
  }

  private func logURL(for id: String) -> URL {
    stateDirectory.appendingPathComponent("\(id).log")
  }

  private var profilesDirectory: URL {
    home.appendingPathComponent("Library/Application Support/warrior-local-services/profiles")
  }

  private var activeProfileURL: URL {
    home.appendingPathComponent("Library/Preferences/warrior-local-services/active-profile.txt")
  }

  private var stateDirectory: URL {
    let configured = ProcessInfo.processInfo.environment["WARRIOR_SERVICE_STATE_DIR"]
    if let configured, !configured.isEmpty {
      return URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath)
    }
    let legacyRoot = ProcessInfo.processInfo.environment["WARRIOR_LOCAL_SERVICES_ROOT"]
      .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
      ?? home.appendingPathComponent("warrior-local-services", isDirectory: true)
    if fileManager.fileExists(atPath: legacyRoot.path) {
      return legacyRoot.appendingPathComponent(".warrior/services", isDirectory: true)
    }
    return home.appendingPathComponent("Library/Application Support/MacScope/developer-services")
  }
}

@MainActor
final class DeveloperServicesStore: ObservableObject {
  @Published private(set) var profile: DeveloperServiceProfile?
  @Published private(set) var profiles: [DeveloperServiceProfile] = []
  @Published private(set) var profileURL: URL?
  @Published private(set) var runtimes: [DeveloperServiceRuntime] = []
  @Published private(set) var git = DeveloperGitStatus()
  @Published private(set) var isBusy = false
  @Published var selected: Set<String> = []
  @Published var output = ""
  @Published var errorMessage = ""
  @Published var forceBuild = false
  @Published private(set) var hasTestLogin: Bool

  var testEmail: String {
    get { UserDefaults.standard.string(forKey: "native.developerTestEmail") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "native.developerTestEmail") }
  }

  private let service: DeveloperServicesService

  init(service: DeveloperServicesService = DeveloperServicesService()) {
    self.service = service
    let savedEmail = UserDefaults.standard.string(forKey: "native.developerTestEmail") ?? ""
    hasTestLogin = !savedEmail.isEmpty && DeveloperCredentialStore.password() != nil
  }

  func refresh() {
    guard !isBusy else { return }
    Task { [weak self, service] in
      do {
        let (profile, url) = try await service.loadActiveProfile()
        let profiles = try await service.listProfiles()
        self?.profiles = profiles.map { $0.0 }
        self?.profile = profile
        self?.profileURL = url
        self?.runtimes = await service.runtimes(profile: profile)
        self?.git = await service.gitStatus(root: profile.root)
        if self?.selected.isEmpty == true {
          self?.selected = Set(profile.services.filter { $0.selected == true }.map(\.id))
        }
        self?.errorMessage = ""
      } catch {
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  func start(_ runtime: DeveloperServiceRuntime) {
    guard let profile else { return }
    perform { service in
      try await service.start(service: runtime.definition, profile: profile)
      return DeveloperCommandResult(title: "Start \(runtime.id)", succeeded: true, output: "Started \(runtime.id)")
    }
  }

  func stop(_ runtime: DeveloperServiceRuntime) {
    perform { service in
      try await service.stop(service: runtime.definition)
      return DeveloperCommandResult(title: "Stop \(runtime.id)", succeeded: true, output: "Stopped \(runtime.id)")
    }
  }

  func startSelected() {
    guard let profile else { return }
    let targets = runtimes.filter { selected.contains($0.id) && $0.state == .stopped }
    perform { service in
      for runtime in targets { try await service.start(service: runtime.definition, profile: profile) }
      return DeveloperCommandResult(title: "Start selected", succeeded: true, output: "Started \(targets.count) services")
    }
  }

  func stopSelected() {
    let targets = runtimes.filter { selected.contains($0.id) && [.running, .starting, .compileFailed].contains($0.state) }
    perform { service in
      for runtime in targets { try await service.stop(service: runtime.definition) }
      return DeveloperCommandResult(title: "Stop selected", succeeded: true, output: "Stopped \(targets.count) services")
    }
  }

  func stopAll() {
    let targets = runtimes.filter { [.running, .starting, .compileFailed].contains($0.state) }
    perform { service in
      for runtime in targets { try await service.stop(service: runtime.definition) }
      return DeveloperCommandResult(title: "Stop all", succeeded: true, output: "Stopped \(targets.count) services")
    }
  }

  func buildSelected() {
    guard let profile else { return }
    let definitions = profile.services.filter { selected.contains($0.id) }
    let forceBuild = forceBuild
    perform { service in try await service.build(services: definitions, profile: profile, force: forceBuild) }
  }

  func buildAll() {
    guard let profile else { return }
    perform { service in try await service.buildAll(profile: profile) }
  }

  func pullAndBuildSelected() {
    guard let profile else { return }
    let definitions = profile.services.filter { selected.contains($0.id) }
    let forceBuild = forceBuild
    perform { service in
      let pull = try await service.pull(root: profile.root)
      guard pull.succeeded else { return pull }
      return try await service.build(
        services: definitions,
        profile: profile,
        force: forceBuild
      )
    }
  }

  func pullAndRunSelected() {
    guard let profile else { return }
    let targets = runtimes.filter { selected.contains($0.id) && $0.state == .stopped }
    perform { service in
      let pull = try await service.pull(root: profile.root)
      guard pull.succeeded else { return pull }
      for runtime in targets {
        try await service.start(service: runtime.definition, profile: profile)
      }
      return DeveloperCommandResult(
        title: "Pull and run selected",
        succeeded: true,
        output: "\(pull.output)\nStarted \(targets.count) services"
      )
    }
  }

  func activateProfile(_ id: String) {
    guard profile?.id != id, !isBusy else { return }
    isBusy = true
    Task { [weak self, service] in
      do {
        try await service.activateProfile(id)
        self?.selected = []
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isBusy = false
      self?.refresh()
    }
  }

  func chooseProjectFolder() {
    guard let profileURL else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Use Project Folder"
    guard panel.runModal() == .OK, let root = panel.url?.path else { return }
    isBusy = true
    Task { [weak self, service] in
      do { try await service.updateProfileRoot(at: profileURL, root: root) }
      catch { self?.errorMessage = error.localizedDescription }
      self?.isBusy = false
      self?.refresh()
    }
  }

  func fetch() {
    guard let profile else { return }
    perform { service in try await service.fetch(root: profile.root) }
  }

  func pull() {
    guard let profile else { return }
    perform { service in try await service.pull(root: profile.root) }
  }

  func showLog(_ runtime: DeveloperServiceRuntime) {
    Task { [weak self, service] in self?.output = await service.recentLog(serviceID: runtime.id) }
  }

  func cancel() {
    Task { [service] in await service.cancel() }
  }

  func openInVSCode() {
    guard let root = profile?.root else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", "Visual Studio Code", root]
    try? process.run()
  }

  func saveTestLogin(email: String, password: String) {
    do {
      let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !email.isEmpty, !password.isEmpty else {
        throw DeveloperServicesError.commandFailed("Email and password are required.")
      }
      try DeveloperCredentialStore.save(password: password)
      testEmail = email
      hasTestLogin = true
      errorMessage = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func clearTestLogin() {
    do { try DeveloperCredentialStore.clear() }
    catch { errorMessage = error.localizedDescription; return }
    testEmail = ""
    hasTestLogin = false
  }

  func openAuthenticatedTestPage() {
    guard let password = DeveloperCredentialStore.password(), !testEmail.isEmpty else {
      errorMessage = "Configure Test Login first."
      return
    }
    guard !isBusy else { return }
    isBusy = true
    errorMessage = ""
    let email = testEmail
    Task { [weak self, service] in
      do {
        let url = try await service.authenticatedTestURL(email: email, password: password)
        NSWorkspace.shared.open(url)
        self?.output = "Authenticated local test page opened."
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isBusy = false
    }
  }

  private func perform(
    operation: @escaping @Sendable (DeveloperServicesService) async throws -> DeveloperCommandResult
  ) {
    guard !isBusy else { return }
    isBusy = true
    errorMessage = ""
    Task { [weak self, service] in
      do {
        let result = try await operation(service)
        self?.output = result.output
        if !result.succeeded { self?.errorMessage = "\(result.title) failed." }
      } catch {
        self?.errorMessage = error.localizedDescription
      }
      self?.isBusy = false
      self?.refresh()
    }
  }
}

private extension JSONEncoder {
  static var prettyDeveloper: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
