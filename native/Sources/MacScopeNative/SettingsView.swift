import AppKit
import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.openWindow) private var openWindow

  @AppStorage("native.settingsTab") private var selectedTab = "general"
  @State private var selectedScanFolder: String?
  @State private var confirmsReset = false

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $selectedTab) {
        generalSettings
          .tabItem { Label("General", systemImage: "gearshape") }
          .tag("general")
        appearanceSettings
          .tabItem { Label("Appearance", systemImage: "paintpalette") }
          .tag("appearance")
        cleanupSettings
          .tabItem { Label("Cleanup", systemImage: "trash") }
          .tag("cleanup")
        aboutSettings
          .tabItem { Label("About", systemImage: "info.circle") }
          .tag("about")
      }
      Divider()
      HStack {
        Button("Reset All Settings", role: .destructive) {
          confirmsReset = true
        }
        Spacer()
      }
      .padding(12)
    }
    .alert("Reset all settings?", isPresented: $confirmsReset) {
      Button("Reset", role: .destructive, action: settings.resetAll)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Monitoring, appearance, and cleanup preferences will return to their defaults.")
    }
  }

  private var generalSettings: some View {
    Form {
      Section("Language & Region") {
        Picker("Language", selection: $settings.language) {
          Text("English").tag(AppLanguage.english)
          Text("简体中文").tag(AppLanguage.simplifiedChinese)
        }
      }

      Section("Monitoring") {
        Picker("Refresh interval", selection: $settings.refreshInterval) {
          Text("0.5 seconds").tag(0.5)
          Text("1 second").tag(1.0)
          Text("2 seconds").tag(2.0)
          Text("5 seconds").tag(5.0)
        }
        Picker("Process rows", selection: $settings.processLimit) {
          Text("5").tag(5)
          Text("10").tag(10)
          Text("20").tag(20)
          Text("50").tag(50)
        }
        Picker("Temperature", selection: $settings.temperatureUnit) {
          Text("Celsius").tag(TemperatureUnit.celsius)
          Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var appearanceSettings: some View {
    Form {
      Section("Window") {
        Picker("Appearance", selection: $settings.appearance) {
          Text("System").tag(AppAppearance.system)
          Text("Light").tag(AppAppearance.light)
          Text("Dark").tag(AppAppearance.dark)
        }
        .pickerStyle(.segmented)

        Toggle("Translucent sidebar", isOn: $settings.sidebarTransparencyEnabled)

        LabeledContent("Sidebar transparency") {
          HStack(spacing: 10) {
            Slider(value: $settings.sidebarTransparency, in: 0...1, step: 0.05)
              .frame(width: 190)
            Text(settings.sidebarTransparency, format: .percent.precision(.fractionLength(0)))
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .frame(width: 42, alignment: .trailing)
          }
        }
        .disabled(!settings.sidebarTransparencyEnabled)
      }

      Section("Colors") {
        Picker("Theme", selection: $settings.themeID) {
          ForEach(ThemePalette.builtIns) { theme in
            HStack {
              HStack(spacing: 2) {
                Circle().fill(theme.cpuColor)
                Circle().fill(theme.memoryColor)
                Circle().fill(theme.diskColor)
                Circle().fill(theme.networkColor)
              }
              .frame(width: 34, height: 8)
              Text(LocalizedStringKey(theme.name))
            }
            .tag(theme.id)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var cleanupSettings: some View {
    Form {
      Section("Cleanup Behavior") {
        Picker("Cache files", selection: $settings.cacheCleanupMode) {
          Text("Move to Trash").tag(CacheCleanupMode.trash)
          Text("Delete Permanently").tag(CacheCleanupMode.delete)
        }
        Toggle("Confirm before cleanup", isOn: $settings.confirmsCleanup)
        Picker("Large file threshold", selection: $settings.largeFileThresholdMB) {
          Text("100 MB").tag(100)
          Text("500 MB").tag(500)
          Text("1 GB").tag(1_024)
          Text("5 GB").tag(5_120)
        }
        Picker("Duplicate minimum size", selection: $settings.duplicateMinimumMB) {
          Text("1 MB").tag(1)
          Text("10 MB").tag(10)
          Text("100 MB").tag(100)
          Text("500 MB").tag(500)
        }
      }

      Section("Scan Folders") {
        List(settings.scanFolderPaths, id: \.self, selection: $selectedScanFolder) { path in
          HStack(spacing: 8) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
            Text(path)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .tag(path)
        }
        .frame(height: 112)

        HStack(spacing: 6) {
          Button(action: addScanFolders) {
            Image(systemName: "plus")
          }
          .help("Add Scan Folder")
          Button(action: removeSelectedScanFolder) {
            Image(systemName: "minus")
          }
          .help("Remove Scan Folder")
          .disabled(selectedScanFolder == nil || settings.scanFolderPaths.count <= 1)
          Spacer()
        }
      }

      Section("Permissions") {
        LabeledContent("Full Disk Access") {
          Button("Open System Settings", action: SystemPermission.openFullDiskAccessSettings)
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private var aboutSettings: some View {
    Form {
      Section {
        HStack(spacing: 14) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
          VStack(alignment: .leading, spacing: 4) {
            Text("MacScope")
              .font(.title2.weight(.semibold))
            Text("Version \(AppMetadata.version) (\(AppMetadata.build))")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
        .padding(.vertical, 6)
      }

      Section("Project") {
        Link(destination: AppLinks.author) {
          GitHubLinkLabel(title: "Author: shenmuoso")
        }
        Link(destination: AppLinks.github) {
          GitHubLinkLabel(title: "Project: great-mac-scope")
        }
      }

      Section("Help & Information") {
        Button {
          openWindow(id: "help")
        } label: {
          Label("MacScope Help", systemImage: "questionmark.circle")
        }
        Button(action: AppLinks.openGitHub) {
          GitHubLinkLabel(title: "View Project on GitHub")
        }
        Button {
          AboutPanel.show(language: settings.language)
        } label: {
          Label("About MacScope", systemImage: "info.circle")
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
  }

  private func addScanFolders() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    var paths = settings.scanFolderPaths
    for url in panel.urls where !paths.contains(url.path) {
      paths.append(url.path)
    }
    settings.scanFolderPaths = paths
  }

  private func removeSelectedScanFolder() {
    guard let selectedScanFolder, settings.scanFolderPaths.count > 1 else { return }
    settings.scanFolderPaths.removeAll { $0 == selectedScanFolder }
    self.selectedScanFolder = nil
  }
}
