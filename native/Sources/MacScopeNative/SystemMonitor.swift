import Combine
import Darwin
import Foundation

@MainActor
final class SystemMonitor: ObservableObject {
  @Published private(set) var snapshot = SystemSnapshot.empty
  @Published private(set) var isRefreshing = false
  @Published var isPaused = false

  var refreshInterval: Double = 1

  private let sampler = SystemSampler()
  private var monitoringTask: Task<Void, Never>?

  func start() {
    guard monitoringTask == nil else { return }
    monitoringTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        if !isPaused {
          await refresh()
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

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    snapshot = await sampler.sample()
    isRefreshing = false
  }

  func refreshNow() {
    Task { await refresh() }
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
}
