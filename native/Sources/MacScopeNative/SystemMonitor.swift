import Combine
import Darwin
import Foundation

@MainActor
final class SystemMetricsStore: ObservableObject {
  @Published private(set) var snapshot = SystemSnapshot.empty

  func update(from source: SystemSnapshot) {
    var metrics = source
    metrics.processes = []
    snapshot = metrics
  }
}

@MainActor
final class SystemMonitor: ObservableObject {
  @Published private(set) var processes: [ProcessRow] = []
  let metrics = SystemMetricsStore()
  private(set) var processHistory: [ProcessHistoryPoint] = []
  private(set) var isRefreshing = false
  @Published var isPaused = false

  var refreshInterval: Double = 1

  private let sampler = SystemSampler()
  private var monitoringTask: Task<Void, Never>?
  private var trackedPID: Int32?
  private var processSamplingRequested = false
  private var processSamplingEnabled = false
  private var processResumeTask: Task<Void, Never>?
  private var processSamplingGeneration = 0
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
    processResumeTask?.cancel()
    processResumeTask = nil
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
    let samplingGeneration = processSamplingGeneration
    let nextSnapshot = await sampler.sample(includeProcesses: shouldSampleProcesses)
    metrics.update(from: nextSnapshot)
    let shouldPublishProcesses =
      shouldSampleProcesses
      && processSamplingRequested
      && samplingGeneration == processSamplingGeneration
    if shouldPublishProcesses {
      recordHistory(for: nextSnapshot)
      processes = nextSnapshot.processes
    }
    isRefreshing = false
  }

  func refreshNow(forceProcessSample: Bool = true) {
    Task { await refresh(forceProcessSample: forceProcessSample) }
  }

  func setProcessSamplingEnabled(_ isEnabled: Bool) {
    guard processSamplingRequested != isEnabled else { return }
    processSamplingRequested = isEnabled
    processSamplingGeneration += 1
    processResumeTask?.cancel()
    processResumeTask = nil

    guard isEnabled else {
      processSamplingEnabled = false
      return
    }

    processSamplingEnabled = false
    let generation = processSamplingGeneration
    processResumeTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 250_000_000)
      guard let self, !Task.isCancelled,
        self.processSamplingRequested,
        self.processSamplingGeneration == generation
      else {
        return
      }
      self.processSamplingEnabled = true
      self.lastProcessSampleAt = -TimeInterval.infinity
      await self.refresh(forceProcessSample: true)
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
