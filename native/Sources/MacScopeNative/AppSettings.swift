import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"

  var id: String { rawValue }
  var locale: Locale { Locale(identifier: rawValue) }
}

enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }
}

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
  case celsius
  case fahrenheit

  var id: String { rawValue }
}

enum CacheCleanupMode: String, CaseIterable, Identifiable, Sendable {
  case trash
  case delete

  var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let language = "native.language"
    static let appearance = "native.appearance"
    static let refreshInterval = "native.refreshInterval"
    static let processLimit = "native.processLimit"
    static let temperatureUnit = "native.temperatureUnit"
    static let themeID = "native.themeID"
    static let customTheme = "native.customTheme"
    static let cacheCleanupMode = "native.cacheCleanupMode"
    static let largeFileThresholdMB = "native.largeFileThresholdMB"
    static let duplicateMinimumMB = "native.duplicateMinimumMB"
    static let scanFolderPaths = "native.scanFolderPaths"
    static let confirmsCleanup = "native.confirmsCleanup"
  }

  @Published var language: AppLanguage {
    didSet { defaults.set(language.rawValue, forKey: Key.language) }
  }

  @Published var appearance: AppAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
  }

  @Published var refreshInterval: Double {
    didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
  }

  @Published var processLimit: Int {
    didSet { defaults.set(processLimit, forKey: Key.processLimit) }
  }

  @Published var temperatureUnit: TemperatureUnit {
    didSet { defaults.set(temperatureUnit.rawValue, forKey: Key.temperatureUnit) }
  }

  @Published var themeID: String {
    didSet { defaults.set(themeID, forKey: Key.themeID) }
  }

  @Published private(set) var customTheme: ThemePalette? {
    didSet {
      if let customTheme, let data = try? JSONEncoder().encode(customTheme) {
        defaults.set(data, forKey: Key.customTheme)
      } else {
        defaults.removeObject(forKey: Key.customTheme)
      }
    }
  }

  @Published var cacheCleanupMode: CacheCleanupMode {
    didSet { defaults.set(cacheCleanupMode.rawValue, forKey: Key.cacheCleanupMode) }
  }

  @Published var largeFileThresholdMB: Int {
    didSet { defaults.set(largeFileThresholdMB, forKey: Key.largeFileThresholdMB) }
  }

  @Published var duplicateMinimumMB: Int {
    didSet { defaults.set(duplicateMinimumMB, forKey: Key.duplicateMinimumMB) }
  }

  @Published var scanFolderPaths: [String] {
    didSet { defaults.set(scanFolderPaths, forKey: Key.scanFolderPaths) }
  }

  @Published var confirmsCleanup: Bool {
    didSet { defaults.set(confirmsCleanup, forKey: Key.confirmsCleanup) }
  }

  var availableThemes: [ThemePalette] {
    ThemePalette.builtIns + (customTheme.map { [$0] } ?? [])
  }

  var activeTheme: ThemePalette {
    availableThemes.first(where: { $0.id == themeID }) ?? ThemePalette.system
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
    appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system

    let savedInterval = defaults.double(forKey: Key.refreshInterval)
    refreshInterval = [0.5, 1, 2, 5].contains(savedInterval) ? savedInterval : 1
    let savedLimit = defaults.integer(forKey: Key.processLimit)
    processLimit = [5, 10, 20, 50].contains(savedLimit) ? savedLimit : 5
    temperatureUnit =
      TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius

    let savedThemeID = defaults.string(forKey: Key.themeID) ?? ThemePalette.system.id
    if let data = defaults.data(forKey: Key.customTheme),
      let theme = try? JSONDecoder().decode(ThemePalette.self, from: data),
      theme.isValid
    {
      customTheme = theme
    } else {
      customTheme = nil
    }
    themeID = savedThemeID

    cacheCleanupMode =
      CacheCleanupMode(rawValue: defaults.string(forKey: Key.cacheCleanupMode) ?? "") ?? .trash
    let savedLargeThreshold = defaults.integer(forKey: Key.largeFileThresholdMB)
    largeFileThresholdMB =
      [100, 500, 1_024, 5_120].contains(savedLargeThreshold)
      ? savedLargeThreshold : 500
    let savedDuplicateMinimum = defaults.integer(forKey: Key.duplicateMinimumMB)
    duplicateMinimumMB =
      [1, 10, 100, 500].contains(savedDuplicateMinimum)
      ? savedDuplicateMinimum : 10

    let savedFolders = defaults.stringArray(forKey: Key.scanFolderPaths) ?? []
    scanFolderPaths = savedFolders.isEmpty ? Self.defaultScanFolderPaths : savedFolders
    confirmsCleanup =
      defaults.object(forKey: Key.confirmsCleanup) == nil
      ? true : defaults.bool(forKey: Key.confirmsCleanup)
  }

  func applyCustomTheme(_ theme: ThemePalette) {
    guard theme.isValid else { return }
    var imported = theme
    imported.id = "custom"
    imported.name = theme.name.isEmpty ? "Custom" : theme.name
    customTheme = imported
    themeID = imported.id
  }

  func resetTheme() {
    customTheme = nil
    themeID = ThemePalette.system.id
  }

  func resetAll() {
    language = .english
    appearance = .system
    refreshInterval = 1
    processLimit = 5
    temperatureUnit = .celsius
    resetTheme()
    cacheCleanupMode = .trash
    largeFileThresholdMB = 500
    duplicateMinimumMB = 10
    scanFolderPaths = Self.defaultScanFolderPaths
    confirmsCleanup = true
  }

  private static var defaultScanFolderPaths: [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Downloads", "Desktop", "Documents", "Movies"].map {
      home.appendingPathComponent($0, isDirectory: true).path
    }
  }
}
