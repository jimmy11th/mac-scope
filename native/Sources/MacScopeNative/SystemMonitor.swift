import Combine
import Darwin
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
  @Published private(set) var snapshot = SystemSnapshot.empty
  private(set) var processHistory: [ProcessHistoryPoint] = []
  private(set) var isRefreshing = false
  @Published var isPaused = false

  var refreshInterval: Double = 1

  private let sampler = SystemSampler()
  private var monitoringTask: Task<Void, Never>?
  private var trackedPID: Int32?
  private var processSamplingEnabled = true
  private var lastProcessSampleAt = -TimeInterval.infinity

  func start() {
    guard monitoringTask == nil else { return }
    monitoringTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        if !isPaused {
          await refresh(forceProcessSample: false)
        }
        let delay = UInt64(max(0.2, refreshInterval) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  func stop() {
    monitoringTask?.cancel()
    monitoringTask = nil
  }

  func refresh(forceProcessSample: Bool = false) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    let now = ProcessInfo.processInfo.systemUptime
    let minimumProcessInterval = max(1, refreshInterval)
    let shouldSampleProcesses =
      processSamplingEnabled
      && (forceProcessSample || now - lastProcessSampleAt >= minimumProcessInterval)
    if shouldSampleProcesses {
      lastProcessSampleAt = now
    }
    var nextSnapshot = await sampler.sample(includeProcesses: shouldSampleProcesses)
    if shouldSampleProcesses {
      recordHistory(for: nextSnapshot)
    } else {
      nextSnapshot.processes = snapshot.processes
    }
    isRefreshing = false
    snapshot = nextSnapshot
  }

  func refreshNow(forceProcessSample: Bool = true) {
    Task { await refresh(forceProcessSample: forceProcessSample) }
  }

  func setProcessSamplingEnabled(_ isEnabled: Bool) {
    guard processSamplingEnabled != isEnabled else { return }
    processSamplingEnabled = isEnabled
    if isEnabled {
      lastProcessSampleAt = -TimeInterval.infinity
      refreshNow(forceProcessSample: true)
    }
  }

  func togglePause() {
    isPaused.toggle()
    if !isPaused {
      refreshNow()
    }
  }

  func send(signal: Int32, to process: ProcessRow) -> String? {
    guard process.pid > 1, process.pid != ProcessInfo.processInfo.processIdentifier else {
      return "This process is protected."
    }
    if Darwin.kill(process.pid, signal) == 0 {
      refreshNow()
      return nil
    }
    return String(cString: strerror(errno))
  }

  func history(for pid: Int32) -> [ProcessHistoryPoint] {
    trackedPID == pid ? processHistory : []
  }

  func trackProcess(_ pid: Int32?) {
    guard trackedPID != pid else { return }
    trackedPID = pid
    processHistory = []
  }

  private func recordHistory(for nextSnapshot: SystemSnapshot) {
    guard let trackedPID else {
      if !processHistory.isEmpty {
        processHistory = []
      }
      return
    }
    let cutoff = nextSnapshot.timestamp.addingTimeInterval(-60)
    guard let process = nextSnapshot.processes.first(where: { $0.pid == trackedPID }) else {
      processHistory = []
      return
    }
    processHistory.removeAll { $0.timestamp < cutoff }
    processHistory.append(
      ProcessHistoryPoint(
        timestamp: nextSnapshot.timestamp,
        cpuPercent: process.cpuPercent,
        memoryBytes: process.memoryBytes,
        diskRate: process.diskReadRate + process.diskWriteRate,
        networkRate: process.networkDownloadRate + process.networkUploadRate
      ))
  }
}
