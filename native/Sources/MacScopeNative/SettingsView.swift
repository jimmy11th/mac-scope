import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  @AppStorage("native.settingsTab") private var selectedTab = "general"
  @State private var selectedScanFolder: String?
  @State private var errorMessage: String?
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
    .alert(
      "Settings could not be updated",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
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
      }

      Section("Colors") {
        Picker("Theme", selection: $settings.themeID) {
          ForEach(settings.availableThemes) { theme in
            HStack {
              Circle()
                .fill(theme.accentColor)
                .frame(width: 9, height: 9)
              Text(LocalizedStringKey(theme.name))
            }
            .tag(theme.id)
          }
        }
        ColorPicker("Accent", selection: themeColorBinding(\.accentHex))
        ColorPicker("CPU", selection: themeColorBinding(\.cpuHex))
        ColorPicker("Memory", selection: themeColorBinding(\.memoryHex))
        ColorPicker("Disk", selection: themeColorBinding(\.diskHex))
        ColorPicker("Network", selection: themeColorBinding(\.networkHex))

        HStack {
          Button {
            importTheme()
          } label: {
            Label("Import", systemImage: "square.and.arrow.down")
          }
          Button {
            exportTheme()
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }
          Spacer()
          Button("Restore System Colors", action: settings.resetTheme)
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

  private func themeColorBinding(_ keyPath: WritableKeyPath<ThemePalette, String>) -> Binding<Color>
  {
    Binding(
      get: { Color(hex: settings.activeTheme[keyPath: keyPath]) },
      set: { color in
        var theme = settings.activeTheme
        theme.name = "Custom"
        theme[keyPath: keyPath] = color.hexString
        settings.applyCustomTheme(theme)
      }
    )
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let theme = try JSONDecoder().decode(ThemePalette.self, from: Data(contentsOf: url))
      guard theme.isValid else { throw ThemeImportError.invalidTheme }
      settings.applyCustomTheme(theme)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func exportTheme() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "MacScope Theme.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(settings.activeTheme).write(to: url, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
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

private enum ThemeImportError: LocalizedError {
  case invalidTheme

  var errorDescription: String? {
    "The theme file contains an invalid name or color value."
  }
}
