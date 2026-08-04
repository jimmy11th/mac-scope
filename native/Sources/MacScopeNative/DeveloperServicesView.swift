import AppKit
import SwiftUI

struct DeveloperServicesView: View {
  @EnvironmentObject private var store: DeveloperServicesStore
  @State private var showsLogin = false
  @State private var loginEmail = ""
  @State private var loginPassword = ""

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let profile = store.profile {
        VStack(spacing: 0) {
          actionBar(profile)
          Divider()
          servicesList
          if !store.output.isEmpty {
            Divider()
            commandOutput
          }
          Divider()
          gitBar(profile)
        }
      } else {
        unavailableView
      }
    }
    .navigationTitle("Developer Services")
    .onAppear(perform: store.refresh)
    .sheet(isPresented: $showsLogin) { loginSheet }
    .task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if !Task.isCancelled { store.refresh() }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(store.profile?.name ?? "Developer Services")
          .font(.title2.weight(.semibold))
        Text(store.profile?.root ?? "Shared Local Services profiles")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Spacer()
      if store.isBusy { ProgressView().controlSize(.small) }
      Menu {
        ForEach(store.profiles) { profile in
          Button {
            store.activateProfile(profile.id)
          } label: {
            if profile.id == store.profile?.id {
              Label(profile.name, systemImage: "checkmark")
            } else {
              Text(profile.name)
            }
          }
        }
        Divider()
        Button("Select Project Folder…", action: store.chooseProjectFolder)
      } label: {
        Label("Profile", systemImage: "folder.badge.gearshape")
      }
      Button(action: store.openInVSCode) {
        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
      }
      .disabled(store.profile == nil)
      Button {
        if store.hasTestLogin { store.openAuthenticatedTestPage() }
        else { prepareLoginSheet() }
      } label: {
        Label("Open Test Page", systemImage: "link")
      }
      Button(action: store.refresh) {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(store.isBusy)
    }
    .padding(.horizontal, 18)
    .frame(height: 70)
  }

  private func actionBar(_ profile: DeveloperServiceProfile) -> some View {
    HStack(spacing: 8) {
      Button(action: store.buildSelected) {
        Label("Build Selected", systemImage: "hammer")
      }
      .buttonStyle(.borderedProminent)
      Button(action: store.startSelected) {
        Label("Run Selected", systemImage: "play.fill")
      }
      Button(action: store.stopSelected) {
        Label("Stop Selected", systemImage: "stop.fill")
      }
      Button(role: .destructive, action: store.stopAll) {
        Label("Stop All", systemImage: "xmark.circle")
      }
      Divider().frame(height: 22)
      Toggle("Force build", isOn: $store.forceBuild)
        .toggleStyle(.checkbox)
      Spacer()
      Text("\(store.selected.count) selected")
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Menu {
        Button("Select All") { store.selected = Set(profile.services.map(\.id)) }
        Button("Select None") { store.selected = [] }
        Divider()
        Button("Build All", action: store.buildAll)
        Button("Pull & Build Selected", action: store.pullAndBuildSelected)
        Button("Pull & Run Selected", action: store.pullAndRunSelected)
        Divider()
        Button("Configure Test Login", action: prepareLoginSheet)
        if store.hasTestLogin { Button("Clear Test Login", action: store.clearTestLogin) }
        if store.isBusy { Button("Cancel Current Operation", action: store.cancel) }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .padding(.horizontal, 18)
    .frame(height: 48)
  }

  private var servicesList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        HStack(spacing: 10) {
          Text("").frame(width: 18)
          Text("Service").frame(maxWidth: .infinity, alignment: .leading)
          Text("State").frame(width: 110, alignment: .leading)
          Text("Port").frame(width: 70, alignment: .trailing)
          Text("PID").frame(width: 70, alignment: .trailing)
          Text("").frame(width: 110)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)

        Divider()

        ForEach(store.runtimes) { runtime in
          serviceRow(runtime)
          if runtime.id != store.runtimes.last?.id { Divider().padding(.leading, 46) }
        }
      }
    }
    .compactNativeScrollers(clearsBackground: true)
  }

  private func serviceRow(_ runtime: DeveloperServiceRuntime) -> some View {
    HStack(spacing: 10) {
      Toggle(
        "",
        isOn: Binding(
          get: { store.selected.contains(runtime.id) },
          set: { selected in
            if selected { store.selected.insert(runtime.id) }
            else { store.selected.remove(runtime.id) }
          }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(runtime.definition.displayName).fontWeight(.medium)
          if runtime.definition.isHost == true {
            Text("HOST")
              .font(.caption2.weight(.bold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.blue.opacity(0.12), in: Capsule())
              .foregroundStyle(.blue)
          }
        }
        Text(runtime.resolvedWorkingDirectory)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Label(stateTitle(runtime), systemImage: stateImage(runtime))
        .font(.caption)
        .foregroundStyle(stateColor(runtime))
        .frame(width: 110, alignment: .leading)
      Text(runtime.definition.port.map { String($0) } ?? "—")
        .monospacedDigit()
        .frame(width: 70, alignment: .trailing)
      Text(runtime.pid.map { String($0) } ?? "—")
        .monospacedDigit()
        .frame(width: 70, alignment: .trailing)

      HStack(spacing: 6) {
        Button {
          if [.running, .starting, .compileFailed].contains(runtime.state) {
            store.stop(runtime)
          } else {
            store.start(runtime)
          }
        } label: {
          Image(systemName: [.running, .starting, .compileFailed].contains(runtime.state) ? "stop.fill" : "play.fill")
        }
        .help([.running, .starting, .compileFailed].contains(runtime.state) ? "Stop" : "Run")
        .disabled(runtime.state == .external || store.isBusy)

        Button { store.showLog(runtime) } label: {
          Image(systemName: "doc.text.magnifyingglass")
        }
        .help("Show Log")

        Button {
          NSWorkspace.shared.open(URL(fileURLWithPath: runtime.resolvedWorkingDirectory))
        } label: {
          Image(systemName: "folder")
        }
        .help("Open Folder")
      }
      .buttonStyle(.borderless)
      .frame(width: 110, alignment: .trailing)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 8)
  }

  private var commandOutput: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Command Output", systemImage: "terminal")
          .font(.caption.weight(.semibold))
        Spacer()
        Button("Clear") { store.output = "" }.buttonStyle(.borderless)
      }
      .padding(.horizontal, 18)
      .frame(height: 34)
      ScrollView([.horizontal, .vertical]) {
        Text(store.output)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
      .frame(height: 150)
      .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
    }
  }

  private func gitBar(_ profile: DeveloperServiceProfile) -> some View {
    HStack(spacing: 10) {
      Label(store.git.summary, systemImage: "arrow.triangle.branch")
        .font(.caption)
        .foregroundStyle(store.git.dirtyCount > 0 ? .orange : .secondary)
      Spacer()
      if !store.errorMessage.isEmpty {
        Text(store.errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(1)
          .help(store.errorMessage)
      }
      Button("Open Profile") {
        if let profileURL = store.profileURL { NSWorkspace.shared.open(profileURL) }
      }
      Button("Fetch", action: store.fetch)
      Button("Pull", action: store.pull)
        .disabled(store.git.dirtyCount > 0 || store.isBusy)
      Button {
        NSWorkspace.shared.open(URL(fileURLWithPath: profile.root))
      } label: {
        Label("Repository", systemImage: "folder")
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 42)
  }

  private var unavailableView: some View {
    VStack(spacing: 14) {
      Image(systemName: "server.rack")
        .font(.system(size: 34))
        .foregroundStyle(.secondary)
      Text("No Local Services Profile")
        .font(.title3.weight(.semibold))
      Text(store.errorMessage.isEmpty ? "Create or import a profile with Warrior Local Services first." : store.errorMessage)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Open Profiles Folder") {
        let folder = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent("Library/Application Support/warrior-local-services/profiles")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
      }
      Button("Refresh", action: store.refresh)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(30)
  }

  private var loginSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Configure Test Login")
        .font(.title3.weight(.semibold))
      Text("The password is stored in macOS Keychain and is never written to the Profile or Activity output.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      TextField("Email", text: $loginEmail)
      SecureField("Password", text: $loginPassword)
      HStack {
        Spacer()
        Button("Cancel") { showsLogin = false }
        Button("Save") {
          store.saveTestLogin(email: loginEmail, password: loginPassword)
          loginPassword = ""
          if store.hasTestLogin { showsLogin = false }
        }
        .buttonStyle(.borderedProminent)
        .disabled(loginEmail.isEmpty || loginPassword.isEmpty)
      }
    }
    .padding(22)
    .frame(width: 430)
  }

  private func prepareLoginSheet() {
    loginEmail = store.testEmail
    loginPassword = ""
    showsLogin = true
  }

  private func stateTitle(_ runtime: DeveloperServiceRuntime) -> String {
    switch runtime.state {
    case .running:
      switch runtime.compileState {
      case .compiled, .notRequired: "Ready"
      case .compiling: "Starting"
      case .failed: "Compile failed"
      case .notRunning: "Running"
      }
    case .starting: "Starting"
    case .compileFailed: "Compile failed"
    case .external: "External"
    case .stopped: "Stopped"
    }
  }

  private func stateImage(_ runtime: DeveloperServiceRuntime) -> String {
    switch runtime.state {
    case .running: runtime.compileState == .compiling ? "clock.fill" : "checkmark.circle.fill"
    case .starting: "clock.fill"
    case .compileFailed: "xmark.octagon.fill"
    case .external: "terminal.fill"
    case .stopped: "circle"
    }
  }

  private func stateColor(_ runtime: DeveloperServiceRuntime) -> Color {
    switch runtime.state {
    case .running: runtime.compileState == .compiling ? .orange : .green
    case .starting: .orange
    case .compileFailed: .red
    case .external: .blue
    case .stopped: .secondary
    }
  }
}
