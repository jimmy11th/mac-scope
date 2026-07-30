import AppKit
import Combine
import Foundation

@MainActor
final class MaintenanceStore: ObservableObject {
  @Published private(set) var junkItems: [MaintenanceItem] = []
  @Published private(set) var applications: [ApplicationRecord] = []
  @Published private(set) var largeFileItems: [MaintenanceItem] = []
  @Published private(set) var duplicateItems: [MaintenanceItem] = []
  @Published private(set) var errorsByTool: [MaintenanceTool: [String]] = [:]
  @Published private(set) var scannedTools: Set<MaintenanceTool> = []
  @Published var activity: MaintenanceActivity?
  @Published private(set) var memoryMessage = ""
  @Published private(set) var memoryNeedsAuthorization = false

  private let service = MaintenanceService()
  private var operationTask: Task<Void, Never>?
  private var lastOperation: LastOperation?
  private var language = AppLanguage.english
  private var lastScanProgressUpdate = -TimeInterval.infinity

  var isBusy: Bool {
    guard let phase = activity?.phase else { return false }
    return phase == .scanning || phase == .working
  }

  var canRetryWithAdministrator: Bool {
    switch lastOperation {
    case .cleanup:
      activity?.failures.contains(where: { $0.kind == .administratorRequired }) == true
    case .memory:
      memoryNeedsAuthorization
    case .none:
      false
    }
  }

  var needsFullDiskAccess: Bool {
    if activity?.failures.contains(where: { $0.kind == .fullDiskAccess }) == true {
      return true
    }
    return activity?.entries.contains { entry in
      entry.state == .failed
        && entry.detail.localizedCaseInsensitiveContains("operation not permitted")
    } == true
  }

  func updateLanguage(_ language: AppLanguage) {
    self.language = language
  }

  func scanJunk() {
    beginScan(tool: .junk, title: l("Scanning Junk")) { [service] reporter in
      try await service.scanJunk(progress: reporter)
    } apply: { result in
      self.junkItems = result.values
    }
  }

  func scanApplications() {
    beginScan(tool: .applications, title: l("Scanning Applications")) { [service] reporter in
      try await service.scanApplications(progress: reporter)
    } apply: { result in
      self.applications = result.values
    }
  }

  func scanLargeFiles(settings: AppSettings) {
    let roots = settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let threshold = settings.largeFileThresholdMB
    beginScan(tool: .largeFiles, title: l("Scanning Large Files")) { [service] reporter in
      try await service.scanLargeFiles(
        roots: roots,
        thresholdMB: threshold,
        progress: reporter
      )
    } apply: { result in
      self.largeFileItems = result.values
    }
  }

  func scanDuplicates(settings: AppSettings) {
    let roots = settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let minimum = settings.duplicateMinimumMB
    beginScan(tool: .duplicates, title: l("Scanning Duplicates")) { [service] reporter in
      try await service.scanDuplicates(
        roots: roots,
        minimumMB: minimum,
        progress: reporter
      )
    } apply: { result in
      self.duplicateItems = result.values
    }
  }

  func cleanJunk(_ items: [MaintenanceItem], settings: AppSettings) {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    beginCleanup(
      tool: .junk,
      title: l("Cleaning Junk"),
      items: items,
      cacheMode: settings.cacheCleanupMode,
      roots: [root]
    )
  }

  func removeLargeFiles(_ items: [MaintenanceItem], settings: AppSettings) {
    beginCleanup(
      tool: .largeFiles,
      title: l("Removing Large Files"),
      items: items,
      cacheMode: .trash,
      roots: settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
  }

  func removeDuplicates(_ items: [MaintenanceItem], settings: AppSettings) {
    beginCleanup(
      tool: .duplicates,
      title: l("Removing Duplicates"),
      items: items,
      cacheMode: .trash,
      roots: settings.scanFolderPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    )
  }

  func uninstall(
    _ record: ApplicationRecord,
    selectedIDs: Set<MaintenanceItem.ID>
  ) {
    let candidates = [record.application] + record.otherCopies + record.residues
    let items = candidates.filter { selectedIDs.contains($0.id) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    beginCleanup(
      tool: .applications,
      title: l("Uninstalling %@", record.application.name),
      items: items,
      cacheMode: .trash,
      roots: [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        home.appendingPathComponent("Applications", isDirectory: true),
        home.appendingPathComponent("Library", isDirectory: true),
      ]
    )
  }

  func releaseMemory(authorize: Bool = false) {
    cancelCurrentOperation()
    memoryMessage = ""
    memoryNeedsAuthorization = false
    lastOperation = .memory
    activity = MaintenanceActivity(
      id: UUID(),
      tool: .memory,
      operation: .memory,
      title: l("Releasing File Cache"),
      phase: .working,
      completed: 0,
      total: 1,
      currentPath: l("Requesting macOS to release inactive file cache"),
      entries: [],
      reclaimedBytes: 0,
      failures: []
    )
    operationTask = Task { [weak self, service] in
      guard let self else { return }
      let result = await service.releaseMemory(authorize: authorize)
      guard !Task.isCancelled else { return }
      switch result {
      case .success:
        memoryNeedsAuthorization = false
        memoryMessage = l("macOS released eligible inactive file cache.")
        activity?.phase = .completed
        activity?.completed = 1
        activity?.currentPath = memoryMessage
      case .authorizationRequired(let message):
        memoryNeedsAuthorization = true
        memoryMessage = message
        activity?.phase = .completed
        activity?.completed = 1
        activity?.currentPath = l("Administrator authorization is required.")
      case .failure(let message):
        memoryNeedsAuthorization = false
        memoryMessage = message
        activity?.phase = .completed
        activity?.completed = 1
        activity?.currentPath = message
      }
    }
  }

  func quitApplication(_ record: ApplicationRecord) {
    let paths = Set(
      ([record.application] + record.otherCopies).map { $0.url.standardizedFileURL.path }
    )
    let matching = NSWorkspace.shared.runningApplications.filter { application in
      guard let path = application.bundleURL?.standardizedFileURL.path else { return false }
      return paths.contains(path)
    }
    matching.forEach { _ = $0.terminate() }

    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 900_000_000)
      guard let self else { return }
      let runningPaths = Set(
        NSWorkspace.shared.runningApplications.compactMap {
          $0.bundleURL?.standardizedFileURL.path
        }
      )
      applications = applications.map { application in
        guard application.id == record.id else { return application }
        let allPaths = ([application.application] + application.otherCopies).map {
          $0.url.standardizedFileURL.path
        }
        return application.replacing(isRunning: allPaths.contains(where: runningPaths.contains))
      }
    }
  }

  func retryWithAdministratorAuthorization() {
    switch lastOperation {
    case .cleanup(let request):
      let failedIDs = Set(
        activity?.failures.filter {
          $0.kind == .administratorRequired
        }.map { $0.item.id } ?? [])
      let retryItems = request.items.filter { failedIDs.contains($0.id) }
      guard !retryItems.isEmpty else { return }
      runCleanup(request.replacing(items: retryItems), authorize: true)
    case .memory:
      releaseMemory(authorize: true)
    case .none:
      break
    }
  }

  func cancelCurrentOperation() {
    operationTask?.cancel()
    operationTask = nil
    if isBusy {
      activity?.phase = .cancelled
      activity?.currentPath = l("Cancelled")
    }
  }

  func dismissActivity() {
    guard !isBusy else { return }
    activity = nil
  }

  private func beginScan<Value: Sendable>(
    tool: MaintenanceTool,
    title: String,
    operation:
      @escaping @Sendable (MaintenanceService.ScanReporter) async throws -> ScanResult<Value>,
    apply: @escaping @MainActor (ScanResult<Value>) -> Void
  ) {
    cancelCurrentOperation()
    lastOperation = nil
    lastScanProgressUpdate = -TimeInterval.infinity
    activity = MaintenanceActivity(
      id: UUID(),
      tool: tool,
      operation: .scan,
      title: title,
      phase: .scanning,
      completed: 0,
      total: 0,
      currentPath: l("Preparing scan"),
      entries: [],
      reclaimedBytes: 0,
      failures: []
    )
    operationTask = Task(priority: .utility) { [weak self] in
      guard let self else { return }
      do {
        let result = try await operation { [weak self] progress in
          await self?.updateScanProgress(progress)
        }
        guard !Task.isCancelled else { return }
        apply(result)
        scannedTools.insert(tool)
        errorsByTool[tool] = result.errors
        if result.errors.isEmpty {
          activity = nil
          return
        }
        activity?.phase = .completed
        activity?.completed = result.scannedCount
        activity?.currentPath = l("Found %lld items", Int64(result.values.count))
        activity?.entries = result.errors.prefix(50).enumerated().map { index, message in
          ActivityEntry(
            id: "error-\(index)",
            name: l("Scan Warning"),
            path: message,
            state: .failed,
            detail: message
          )
        }
      } catch is CancellationError {
        activity?.phase = .cancelled
        activity?.currentPath = l("Cancelled")
      } catch {
        errorsByTool[tool] = [error.localizedDescription]
        activity?.phase = .completed
        activity?.currentPath = error.localizedDescription
        activity?.entries = [
          ActivityEntry(
            id: "scan-error",
            name: l("Scan Failed"),
            path: "",
            state: .failed,
            detail: error.localizedDescription
          )
        ]
      }
    }
  }

  private func updateScanProgress(_ progress: ScanProgress) {
    guard activity?.phase == .scanning else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastScanProgressUpdate >= 0.1 else { return }
    lastScanProgressUpdate = now
    guard var nextActivity = activity else { return }
    nextActivity.completed = progress.scannedCount
    nextActivity.currentPath = progress.currentPath
    activity = nextActivity
  }

  private func beginCleanup(
    tool: MaintenanceTool,
    title: String,
    items: [MaintenanceItem],
    cacheMode: CacheCleanupMode,
    roots: [URL]
  ) {
    guard !items.isEmpty else { return }
    let request = CleanupRequest(
      tool: tool,
      title: title,
      items: items,
      cacheMode: cacheMode,
      roots: roots
    )
    lastOperation = .cleanup(request)
    runCleanup(request, authorize: false)
  }

  private func runCleanup(_ request: CleanupRequest, authorize: Bool) {
    cancelCurrentOperation()
    activity = MaintenanceActivity(
      id: UUID(),
      tool: request.tool,
      operation: .cleanup,
      title: authorize ? l("Authorizing Cleanup") : request.title,
      phase: .working,
      completed: 0,
      total: request.items.count,
      currentPath: l("Preparing"),
      entries: request.items.map {
        ActivityEntry(
          id: $0.id,
          name: $0.name,
          path: $0.url.path,
          state: .pending,
          detail: ""
        )
      },
      reclaimedBytes: 0,
      failures: []
    )
    operationTask = Task { [weak self, service] in
      guard let self else { return }
      let result = await service.cleanup(
        items: request.items,
        cacheMode: request.cacheMode,
        allowedRoots: request.roots,
        authorize: authorize
      ) { [weak self] progress in
        await self?.updateCleanupProgress(progress)
      }
      guard !Task.isCancelled else { return }
      activity?.phase = .completed
      activity?.completed = request.items.count
      activity?.currentPath =
        result.failures.isEmpty
        ? l("Completed %lld items", Int64(result.completed.count))
        : l("Completed with %lld issues", Int64(result.failures.count))
      activity?.reclaimedBytes = result.reclaimedBytes
      activity?.failures = result.failures
      removeCompleted(result.completed, from: request.tool)
    }
  }

  private func updateCleanupProgress(_ progress: CleanupProgress) {
    guard activity?.phase == .working else { return }
    activity?.completed = progress.completed
    activity?.total = progress.total
    activity?.currentPath = progress.item.url.path
    if let index = activity?.entries.firstIndex(where: { $0.id == progress.item.id }) {
      activity?.entries[index].state = progress.state
      activity?.entries[index].detail = progress.detail
    }
  }

  private func removeCompleted(_ items: [MaintenanceItem], from tool: MaintenanceTool) {
    let ids = Set(items.map(\.id))
    switch tool {
    case .junk:
      junkItems.removeAll { ids.contains($0.id) }
    case .largeFiles:
      largeFileItems.removeAll { ids.contains($0.id) }
    case .duplicates:
      duplicateItems.removeAll { ids.contains($0.id) }
      let remainingGroups = Dictionary(grouping: duplicateItems, by: \.group)
        .filter { $0.value.count > 1 }
        .map(\.key)
      duplicateItems.removeAll { !remainingGroups.contains($0.group) }
    case .applications:
      applications = applications.compactMap { record in
        if ids.contains(record.application.id) {
          let remainingCopies = record.otherCopies.filter { !ids.contains($0.id) }
          guard let promoted = remainingCopies.first else { return nil }
          return ApplicationRecord(
            application: promoted,
            bundleIdentifier: record.bundleIdentifier,
            version: record.version,
            residues: record.residues.filter { !ids.contains($0.id) },
            otherCopies: Array(remainingCopies.dropFirst()),
            isRunning: record.isRunning
          )
        }
        return ApplicationRecord(
          application: record.application,
          bundleIdentifier: record.bundleIdentifier,
          version: record.version,
          residues: record.residues.filter { !ids.contains($0.id) },
          otherCopies: record.otherCopies.filter { !ids.contains($0.id) },
          isRunning: record.isRunning
        )
      }
    case .memory:
      break
    }
  }

  private func l(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: language, arguments: arguments)
  }
}

private struct CleanupRequest {
  let tool: MaintenanceTool
  let title: String
  let items: [MaintenanceItem]
  let cacheMode: CacheCleanupMode
  let roots: [URL]

  func replacing(items: [MaintenanceItem]) -> CleanupRequest {
    CleanupRequest(tool: tool, title: title, items: items, cacheMode: cacheMode, roots: roots)
  }
}

private enum LastOperation {
  case cleanup(CleanupRequest)
  case memory
}
