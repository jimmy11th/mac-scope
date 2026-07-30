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
  @EnvironmentObject private var navigation: AppNavigation

  @State private var searchText = ""
  @State private var selection: ProcessRow.ID?
  @State private var sortOrder = [
    KeyPathComparator(\ProcessRow.cpuPercent, order: .reverse)
  ]
  @State private var pendingCommand: ProcessCommand?
  @State private var operationError: String?
  @State private var showsInspector = false

  private var selectedProcess: ProcessRow? {
    guard let pid = selection else { return nil }
    return monitor.processes.first { $0.pid == pid }
  }

  private var visibleProcesses: [ProcessRow] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let filtered = monitor.processes.filter { process in
      query.isEmpty
        || process.name.lowercased().contains(query)
        || String(process.pid).contains(query)
    }
    let sorted = filtered.sorted(using: sortOrder)
    var visible = Array(sorted.prefix(settings.processLimit))
    if query.isEmpty, let selection,
      !visible.contains(where: { $0.pid == selection }),
      let selected = sorted.first(where: { $0.pid == selection })
    {
      if visible.isEmpty {
        visible.append(selected)
      } else {
        visible[visible.count - 1] = selected
      }
    }
    return visible
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        SystemOverview(
          temperatureUnit: settings.temperatureUnit,
          language: settings.language,
          theme: settings.activeTheme
        )
        Divider()
        processHeader
        processTable
        Divider()
        SystemStatusBar(
          isPaused: monitor.isPaused,
          processCount: monitor.processes.count
        )
      }
      if showsInspector {
        Divider()
        inspectorPane
          .frame(width: 340)
      }
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

        Button(action: { monitor.refreshNow() }) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh Now")
        .disabled(monitor.isRefreshing)
      }

      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          toggleInspector()
        } label: {
          Label("Process Info", systemImage: "info.circle")
        }
        .help("Show Process Info")
        .disabled(selectedProcess == nil)

        Menu {
          Button("Show Process Info") {
            showInspector()
          }
          Divider()
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

      }
    }
    .onChange(of: selection) { selected in
      monitor.trackProcess(selected)
    }
    .onChange(of: navigation.processInspectionRequest) { request in
      handleProcessInspection(request)
    }
    .onAppear {
      handleProcessInspection(navigation.processInspectionRequest)
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

  @ViewBuilder
  private var inspectorPane: some View {
    if let selectedProcess {
      ProcessInspectorView(
        process: selectedProcess,
        history: monitor.history(for: selectedProcess.pid),
        theme: settings.activeTheme,
        onClose: { showsInspector = false }
      )
    } else {
      VStack(spacing: 0) {
        HStack {
          Spacer()
          Button {
            showsInspector = false
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .help("Close Process Info")
        }
        .padding(12)
        Spacer()
        VStack(spacing: 8) {
          Image(systemName: "info.circle")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("Select a process to view its activity.")
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

      TableColumn("Disk Read", value: \.diskReadRate) { process in
        Text(DisplayFormat.rate(process.diskReadRate))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Disk Write", value: \.diskWriteRate) { process in
        Text(DisplayFormat.rate(process.diskWriteRate))
          .monospacedDigit()
      }
      .width(92)

      TableColumn("Download", value: \.networkDownloadRate) { process in
        Text(DisplayFormat.rate(process.networkDownloadRate))
          .monospacedDigit()
      }
      .width(96)

      TableColumn("Upload", value: \.networkUploadRate) { process in
        Text(DisplayFormat.rate(process.networkUploadRate))
          .monospacedDigit()
      }
      .width(92)

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
        let process = monitor.processes.first(where: { $0.pid == pid })
      {
        Button("Show Process Info") { showInspector() }
        Divider()
        Button("Quit Process") { pendingCommand = .quit(process) }
        Button("Force Quit", role: .destructive) {
          pendingCommand = .forceQuit(process)
        }
      }
    }
    .simultaneousGesture(
      TapGesture(count: 2)
        .onEnded {
          guard selectedProcess != nil else { return }
          showInspector()
        }
    )
    .compactNativeScrollers()
  }

  private func toggleInspector() {
    if showsInspector {
      showsInspector = false
    } else {
      showInspector()
    }
  }

  private func showInspector() {
    guard !showsInspector else { return }
    showsInspector = true
    guard let window = AppWindowActions.mainWindow,
      window.frame.width < 1_180,
      let visibleFrame = window.screen?.visibleFrame
    else {
      return
    }

    var frame = window.frame
    let targetWidth = min(1_180, visibleFrame.width)
    let centeredOrigin = frame.midX - targetWidth / 2
    frame.origin.x = min(
      visibleFrame.maxX - targetWidth,
      max(visibleFrame.minX, centeredOrigin)
    )
    frame.size.width = targetWidth
    window.setFrame(frame, display: true, animate: true)
  }

  private func handleProcessInspection(_ request: ProcessInspectionRequest?) {
    guard let request,
      monitor.processes.contains(where: { $0.pid == request.pid })
    else {
      return
    }
    selection = request.pid
    monitor.trackProcess(request.pid)
    showInspector()
    navigation.completeProcessInspection(request)
  }
}

private struct SystemOverview: View {
  @EnvironmentObject private var metrics: SystemMetricsStore

  let temperatureUnit: TemperatureUnit
  let language: AppLanguage
  let theme: ThemePalette

  var body: some View {
    let snapshot = metrics.snapshot
    HStack(spacing: 0) {
      MetricView(
        title: "CPU",
        systemImage: "cpu",
        color: theme.cpuColor,
        value: DisplayFormat.percent(snapshot.cpu.total),
        detail: localized(
          "User %@  System %@",
          DisplayFormat.percent(snapshot.cpu.user),
          DisplayFormat.percent(snapshot.cpu.system)
        ),
        progress: snapshot.cpu.total / 100,
        accessory: DisplayFormat.temperature(
          snapshot.cpu.temperature.socCelsius,
          unit: temperatureUnit
        ) ?? "Unavailable",
        accessoryColor: MetricColorScale.temperature(
          celsius: snapshot.cpu.temperature.socCelsius
        ),
        progressColor: MetricColorScale.utilization(fraction: snapshot.cpu.total / 100)
      )
      Divider()
      MetricView(
        title: "Memory",
        systemImage: "memorychip",
        color: theme.memoryColor,
        value: localized(
          "Used %@ / %@",
          DisplayFormat.bytes(snapshot.memory.used),
          DisplayFormat.bytes(snapshot.memory.total)
        ),
        detail: localized("%@ available", DisplayFormat.bytes(snapshot.memory.available)),
        progress: snapshot.memory.fraction,
        accessory: nil,
        accessoryColor: .secondary,
        progressColor: MetricColorScale.utilization(fraction: snapshot.memory.fraction)
      )
      Divider()
      MetricView(
        title: "Disk",
        systemImage: "internaldrive",
        color: theme.diskColor,
        value: localized(
          "Used %@ / %@",
          DisplayFormat.bytes(snapshot.disk.used),
          DisplayFormat.bytes(snapshot.disk.total)
        ),
        detail:
          "↓ \(DisplayFormat.rate(snapshot.disk.readRate))  ↑ \(DisplayFormat.rate(snapshot.disk.writeRate))",
        progress: snapshot.disk.fraction,
        accessory: nil,
        accessoryColor: .secondary,
        progressColor: MetricColorScale.utilization(fraction: snapshot.disk.fraction)
      )
      Divider()
      MetricView(
        title: "Network",
        systemImage: "network",
        color: theme.networkColor,
        value: "↓ \(DisplayFormat.rate(snapshot.network.downloadRate))",
        detail: "↑ \(DisplayFormat.rate(snapshot.network.uploadRate))",
        progress: nil,
        accessory: nil,
        accessoryColor: .secondary,
        valueColor: MetricColorScale.network(rate: snapshot.network.downloadRate),
        detailColor: MetricColorScale.network(rate: snapshot.network.uploadRate)
      )
    }
    .frame(height: 118)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: language, arguments: arguments)
  }
}

private struct SystemStatusBar: View {
  @EnvironmentObject private var metrics: SystemMetricsStore

  let isPaused: Bool
  let processCount: Int

  var body: some View {
    HStack {
      if isPaused {
        Label("Monitoring Paused", systemImage: "pause.circle.fill")
          .foregroundStyle(.secondary)
      } else {
        Text("Updated \(metrics.snapshot.timestamp.formatted(date: .omitted, time: .standard))")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text("\(processCount) processes")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .frame(height: 28)
  }
}

private struct MetricView: View {
  let title: String
  let systemImage: String
  let color: Color
  let value: String
  let detail: String
  let progress: Double?
  let accessory: String?
  let accessoryColor: Color
  let valueColor: Color
  let detailColor: Color
  let progressColor: Color?

  init(
    title: String,
    systemImage: String,
    color: Color,
    value: String,
    detail: String,
    progress: Double?,
    accessory: String?,
    accessoryColor: Color,
    valueColor: Color = .primary,
    detailColor: Color = .secondary,
    progressColor: Color? = nil
  ) {
    self.title = title
    self.systemImage = systemImage
    self.color = color
    self.value = value
    self.detail = detail
    self.progress = progress
    self.accessory = accessory
    self.accessoryColor = accessoryColor
    self.valueColor = valueColor
    self.detailColor = detailColor
    self.progressColor = progressColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(color)
        Spacer(minLength: 0)
        if let accessory {
          Text(accessory)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(accessoryColor)
            .monospacedDigit()
            .lineLimit(1)
        }
      }
      Text(value)
        .font(.title3.weight(.semibold))
        .foregroundStyle(valueColor)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      if let progress {
        ProgressView(value: min(1, max(0, progress)))
          .tint(progressColor ?? color)
      } else {
        Spacer(minLength: 4)
      }
      Text(detail)
        .font(.caption)
        .foregroundStyle(detailColor)
        .monospacedDigit()
        .lineLimit(1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
