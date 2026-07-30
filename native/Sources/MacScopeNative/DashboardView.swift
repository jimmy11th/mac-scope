import AppKit
import Darwin
import SwiftUI

private enum ProcessCommand: Identifiable {
  case quit(ProcessRow)
  case forceQuit(ProcessRow)

  var id: String {
    switch self {
    case .quit(let process): "quit-\(process.pid)"
    case .forceQuit(let process): "force-\(process.pid)"
    }
  }

  var process: ProcessRow {
    switch self {
    case .quit(let process), .forceQuit(let process): process
    }
  }

  var signal: Int32 {
    switch self {
    case .quit: SIGTERM
    case .forceQuit: SIGKILL
    }
  }

  var title: String {
    switch self {
    case .quit(let process): "Quit \(process.name)?"
    case .forceQuit(let process): "Force Quit \(process.name)?"
    }
  }

  var actionTitle: String {
    switch self {
    case .quit: "Quit"
    case .forceQuit: "Force Quit"
    }
  }
}

struct DashboardView: View {
  @EnvironmentObject private var monitor: SystemMonitor
  @EnvironmentObject private var settings: AppSettings

  @State private var searchText = ""
  @State private var selection = Set<ProcessRow.ID>()
  @State private var sortOrder = [
    KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)
  ]
  @State private var pendingCommand: ProcessCommand?
  @State private var operationError: String?

  private var selectedProcess: ProcessRow? {
    guard let pid = selection.first else { return nil }
    return monitor.snapshot.processes.first { $0.pid == pid }
  }

  private var visibleProcesses: [ProcessRow] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = monitor.snapshot.processes.filter { process in
      query.isEmpty
        || process.name.lowercased().contains(query)
        || String(process.pid).contains(query)
    }
    return Array(filtered.sorted(using: sortOrder).prefix(settings.processLimit))
  }

  var body: some View {
    VStack(spacing: 0) {
      SystemOverview(snapshot: monitor.snapshot)
      Divider()
      processHeader
      processTable
      Divider()
      statusBar
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle("MacScope")
    .searchable(text: $searchText, placement: .toolbar, prompt: "Search Processes")
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button(action: monitor.togglePause) {
          Label(
            monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring",
            systemImage: monitor.isPaused ? "play.fill" : "pause.fill"
          )
        }
        .help(monitor.isPaused ? "Resume Monitoring" : "Pause Monitoring")

        Button(action: monitor.refreshNow) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh Now")
        .disabled(monitor.isRefreshing)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Menu {
          Button("Quit Process") {
            if let selectedProcess {
              pendingCommand = .quit(selectedProcess)
            }
          }
          Button("Force Quit", role: .destructive) {
            if let selectedProcess {
              pendingCommand = .forceQuit(selectedProcess)
            }
          }
        } label: {
          Label("Process Actions", systemImage: "ellipsis.circle")
        }
        .help("Process Actions")
        .disabled(selectedProcess == nil)

        Button {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
      }
    }
    .alert(item: $pendingCommand) { command in
      Alert(
        title: Text(command.title),
        message: Text("PID \(command.process.pid)"),
        primaryButton: .destructive(Text(command.actionTitle)) {
          operationError = monitor.send(signal: command.signal, to: command.process)
        },
        secondaryButton: .cancel()
      )
    }
    .alert(
      "The process could not be managed",
      isPresented: Binding(
        get: { operationError != nil },
        set: { if !$0 { operationError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { operationError = nil }
    } message: {
      Text(operationError ?? "")
    }
  }

  private var processHeader: some View {
    HStack(spacing: 8) {
      Text("Processes")
        .font(.headline)
      Text("Top \(settings.processLimit)")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Spacer()
      if let selectedProcess {
        Text("PID \(selectedProcess.pid)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: 44)
  }

  private var processTable: some View {
    Table(visibleProcesses, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Process", value: \.name) { process in
        Text(process.name)
          .lineLimit(1)
          .help(process.name)
      }
      .width(min: 180, ideal: 260)

      TableColumn("PID", value: \.pid) { process in
        Text(process.pid, format: .number.grouping(.never))
          .monospacedDigit()
      }
      .width(70)

      TableColumn("CPU", value: \.cpuPercent) { process in
        Text(DisplayFormat.percent(process.cpuPercent))
          .monospacedDigit()
      }
      .width(76)

      TableColumn("Memory", value: \.memoryBytes) { process in
        Text(DisplayFormat.bytes(process.memoryBytes))
          .monospacedDigit()
      }
      .width(100)

      TableColumn("Threads", value: \.threadCount) { process in
        Text(process.threadCount, format: .number.grouping(.never))
          .monospacedDigit()
      }
      .width(76)

      TableColumn("Runtime", value: \.runtime) { process in
        Text(DisplayFormat.duration(process.runtime))
          .monospacedDigit()
      }
      .width(90)
    }
    .contextMenu(forSelectionType: ProcessRow.ID.self) { selected in
      if let pid = selected.first,
        let process = monitor.snapshot.processes.first(where: { $0.pid == pid })
      {
        Button("Quit Process") { pendingCommand = .quit(process) }
        Button("Force Quit", role: .destructive) {
          pendingCommand = .forceQuit(process)
        }
      }
    }
  }

  private var statusBar: some View {
    HStack {
      if monitor.isPaused {
        Label("Monitoring Paused", systemImage: "pause.circle.fill")
          .foregroundStyle(.secondary)
      } else {
        Text("Updated \(monitor.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(monitor.snapshot.processes.count) processes")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 28)
  }
}

private struct SystemOverview: View {
  let snapshot: SystemSnapshot

  var body: some View {
    HStack(spacing: 0) {
      MetricView(
        title: "CPU",
        systemImage: "cpu",
        color: .blue,
        value: DisplayFormat.percent(snapshot.cpu.total),
        detail:
          "User \(DisplayFormat.percent(snapshot.cpu.user))  System \(DisplayFormat.percent(snapshot.cpu.system))",
        progress: snapshot.cpu.total / 100
      )
      Divider()
      MetricView(
        title: "Memory",
        systemImage: "memorychip",
        color: .green,
        value:
          "\(DisplayFormat.bytes(snapshot.memory.used)) of \(DisplayFormat.bytes(snapshot.memory.total))",
        detail: "\(DisplayFormat.bytes(snapshot.memory.available)) available",
        progress: snapshot.memory.fraction
      )
      Divider()
      MetricView(
        title: "Disk",
        systemImage: "internaldrive",
        color: .orange,
        value:
          "\(DisplayFormat.bytes(snapshot.disk.used)) of \(DisplayFormat.bytes(snapshot.disk.total))",
        detail:
          "↓ \(DisplayFormat.rate(snapshot.disk.readRate))  ↑ \(DisplayFormat.rate(snapshot.disk.writeRate))",
        progress: snapshot.disk.fraction
      )
      Divider()
      MetricView(
        title: "Network",
        systemImage: "network",
        color: .pink,
        value: "↓ \(DisplayFormat.rate(snapshot.network.downloadRate))",
        detail: "↑ \(DisplayFormat.rate(snapshot.network.uploadRate))",
        progress: nil
      )
    }
    .frame(height: 118)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

private struct MetricView: View {
  let title: String
  let systemImage: String
  let color: Color
  let value: String
  let detail: String
  let progress: Double?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
      Text(value)
        .font(.title3.weight(.semibold))
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      if let progress {
        ProgressView(value: min(1, max(0, progress)))
          .tint(color)
      } else {
        Spacer(minLength: 4)
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
