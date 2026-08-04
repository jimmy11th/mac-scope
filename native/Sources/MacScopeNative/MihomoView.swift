import AppKit
import SwiftUI

struct MihomoView: View {
  @EnvironmentObject private var store: MihomoStore

  @State private var binaryPath = ""
  @State private var configPath = ""
  @State private var directDomains = ""
  @State private var autoStart = false
  @State private var bindingDomain = ""
  @State private var bindingOutbound = ""
  @State private var probeURL = "https://tcb.cloud.tencent.com/"
  @State private var probeRepeats = 3
  @State private var probeGroup = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(spacing: 16) {
          statusCard
          configurationCard
          if store.status.isRunning {
            policyGroupsCard
            siteRoutesCard
            probeCard
          }
          if let report = store.probeReport { probeResultsCard(report) }
        }
        .padding(18)
      }
      .compactNativeScrollers(clearsBackground: true)
    }
    .navigationTitle("Mihomo")
    .onAppear {
      synchronizeEdits()
      store.refresh()
    }
    .onChange(of: store.settings) { _ in synchronizeEdits() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Mihomo Routing")
          .font(.title2.weight(.semibold))
        Text("Local proxy lifecycle, policy groups, and site-specific routes")
          .foregroundStyle(.secondary)
      }
      Spacer()
      if store.isBusy { ProgressView().controlSize(.small) }
      Button(action: store.refresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(store.isBusy)
    }
    .padding(.horizontal, 18)
    .frame(height: 70)
  }

  private var statusCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 14) {
          Label(
            store.status.isRunning ? "Running" : "Stopped",
            systemImage: store.status.isRunning ? "checkmark.circle.fill" : "stop.circle"
          )
          .foregroundStyle(store.status.isRunning ? .green : .secondary)

          if store.status.isRunning {
            metric("PID", String(store.status.pid))
            metric("Node", store.status.currentNode)
            metric("CPU", store.status.cpuPercent.formatted(.number.precision(.fractionLength(1))) + "%")
            metric(
              "Memory",
              ByteCountFormatter.string(fromByteCount: Int64(store.status.memoryBytes), countStyle: .memory)
            )
          }
          Spacer()
          Button(store.status.isRunning ? "Stop" : "Start") {
            store.status.isRunning ? store.stop() : store.start()
          }
          .buttonStyle(.borderedProminent)
          .tint(store.status.isRunning ? .red : .accentColor)
          .disabled(store.isBusy)
        }

        if !store.operationMessage.isEmpty {
          Text(store.operationMessage).font(.caption).foregroundStyle(.secondary)
        }
        if !store.errorMessage.isEmpty {
          Text(store.errorMessage).font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
        } else if !store.status.lastError.isEmpty {
          Text(store.status.lastError).font(.caption).foregroundStyle(.orange)
            .textSelection(.enabled)
        }
      }
      .padding(4)
    } label: {
      Label("Runtime", systemImage: "bolt.horizontal.circle")
    }
  }

  private var configurationCard: some View {
    GroupBox {
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          Text("Binary")
          TextField("/opt/homebrew/bin/mihomo", text: $binaryPath)
          Button("Choose…", action: chooseBinary)
        }
        GridRow {
          Text("YAML Config")
          TextField("~/.config/mihomo/config.yaml", text: $configPath)
          Button("Choose…", action: chooseConfig)
        }
        GridRow {
          Text("Direct Domains")
          TextField("Comma, space, or newline separated", text: $directDomains)
          Text("")
        }
        GridRow {
          Text("Startup")
          Toggle("Start Mihomo with MacScope", isOn: $autoStart)
          Text("")
        }
      }
      .textFieldStyle(.roundedBorder)
      .disabled(store.status.isRunning)

      if store.status.isRunning {
        Text("Stop Mihomo before changing its binary, config, domains, or startup setting.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }

      HStack {
        Text("Settings are validated with `mihomo -t` before they are saved.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Open Config") { NSWorkspace.shared.open(URL(fileURLWithPath: configPath)) }
          .disabled(configPath.isEmpty)
        Button("Open Log") {
          NSWorkspace.shared.open(URL(fileURLWithPath: store.status.logPath))
        }
        .disabled(store.status.logPath.isEmpty)
        Button("Restore Backup", action: store.restoreBackup)
          .disabled(store.isBusy)
        Button("Validate & Save", action: saveConfiguration)
          .buttonStyle(.borderedProminent)
          .disabled(store.isBusy || store.status.isRunning)
      }
      .padding(.top, 10)
    } label: {
      Label("Configuration", systemImage: "slider.horizontal.3")
    }
  }

  private var policyGroupsCard: some View {
    GroupBox {
      if store.catalog.groups.isEmpty {
        Text("No policy groups returned by the local controller.")
          .foregroundStyle(.secondary)
      } else {
        VStack(spacing: 8) {
          ForEach(store.catalog.groups) { group in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(group.name).fontWeight(.medium)
                Text(group.type).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Picker(
                group.name,
                selection: Binding(
                  get: { group.current },
                  set: { node in
                    guard node != group.current else { return }
                    store.selectProxy(group: group.name, node: node)
                  }
                )
              ) {
                ForEach(group.members, id: \.self) { Text($0).tag($0) }
              }
              .labelsHidden()
              .frame(width: 300)
              .disabled(store.isBusy)
            }
            if group.id != store.catalog.groups.last?.id { Divider() }
          }
        }
      }
    } label: {
      Label("Policy Groups", systemImage: "point.3.connected.trianglepath.dotted")
    }
  }

  private var siteRoutesCard: some View {
    GroupBox {
      VStack(spacing: 10) {
        ForEach(store.settings.siteBindings) { binding in
          HStack {
            Text(binding.domain).textSelection(.enabled)
            Spacer()
            Text(binding.outbound).foregroundStyle(.secondary).textSelection(.enabled)
            Button(role: .destructive) {
              store.removeBinding(domain: binding.domain)
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
        if !store.settings.siteBindings.isEmpty { Divider() }
        HStack {
          TextField("example.com", text: $bindingDomain)
          Picker("Outbound", selection: $bindingOutbound) {
            Text("Select a node or group").tag("")
            Section("Policy Groups") {
              ForEach(store.catalog.groups) { Text($0.name).tag($0.name) }
            }
            Section("Nodes") {
              ForEach(store.catalog.nodes) { Text($0.name).tag($0.name) }
            }
          }
          .frame(width: 300)
          Button("Add Route") {
            store.saveBinding(domain: bindingDomain, outbound: bindingOutbound)
            bindingDomain = ""
          }
          .disabled(bindingDomain.isEmpty || bindingOutbound.isEmpty || store.isBusy)
        }
      }
    } label: {
      Label("Site Routes", systemImage: "arrow.triangle.branch")
    }
  }

  private var probeCard: some View {
    GroupBox {
      HStack {
        TextField("https://service.example.com/health", text: $probeURL)
        Picker("Group", selection: $probeGroup) {
          Text("All nodes").tag("")
          ForEach(store.catalog.groups) { Text($0.name).tag($0.name) }
        }
        .frame(width: 190)
        Stepper("\(probeRepeats)×", value: $probeRepeats, in: 1...10)
          .frame(width: 90)
        Button("Test Nodes") {
          guard let url = URL(string: probeURL) else {
            store.errorMessage = "Enter a valid HTTP(S) test URL."
            return
          }
          store.probe(url: url, repeats: probeRepeats, group: probeGroup.isEmpty ? nil : probeGroup)
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isBusy)
      }
      Text("Each node is tested against the real business URL through Mihomo's local controller.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    } label: {
      Label("Targeted Node Test", systemImage: "speedometer")
    }
  }

  private func probeResultsCard(_ report: MihomoProbeReport) -> some View {
    GroupBox {
      VStack(spacing: 8) {
        ForEach(report.results) { result in
          HStack {
            Image(systemName: result.successes == result.attempts ? "checkmark.circle.fill" : "exclamationmark.circle")
              .foregroundStyle(result.successes == result.attempts ? .green : .orange)
            Text(result.name).lineLimit(1)
            Spacer()
            Text("\(result.successes)/\(result.attempts)").monospacedDigit()
            Text("median \(result.medianMilliseconds) ms").monospacedDigit().frame(width: 110, alignment: .trailing)
            Text("P95 \(result.p95Milliseconds) ms").monospacedDigit().frame(width: 90, alignment: .trailing)
          }
          if result.id != report.results.last?.id { Divider() }
        }
      }
    } label: {
      Label("Probe Results", systemImage: "list.bullet.clipboard")
    }
  }

  private func metric(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(value).font(.caption.monospacedDigit()).lineLimit(1)
    }
  }

  private func synchronizeEdits() {
    binaryPath = store.settings.binaryPath
    configPath = store.settings.configPath
    directDomains = store.settings.directDomains.joined(separator: ", ")
    autoStart = store.settings.autoStart
  }

  private func saveConfiguration() {
    store.configure(
      MihomoSettings(
        binaryPath: binaryPath,
        configPath: configPath,
        directDomains: [directDomains],
        autoStart: autoStart,
        siteBindings: store.settings.siteBindings
      )
    )
  }

  private func chooseBinary() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Mihomo"
    if panel.runModal() == .OK { binaryPath = panel.url?.path ?? binaryPath }
  }

  private func chooseConfig() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose Config"
    if panel.runModal() == .OK { configPath = panel.url?.path ?? configPath }
  }
}
