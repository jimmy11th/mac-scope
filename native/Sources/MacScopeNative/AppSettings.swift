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
    static let sidebarTransparencyEnabled = "native.sidebarTransparencyEnabled"
    static let sidebarTransparency = "native.sidebarTransparency"
    static let refreshInterval = "native.refreshInterval"
    static let processLimit = "native.processLimit"
    static let processLimitDefault20Applied = "native.processLimitDefault20Applied"
    static let refreshIntervalDefault2Applied = "native.refreshIntervalDefault2Applied"
    static let temperatureUnit = "native.temperatureUnit"
    static let themeID = "native.themeID"
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

  @Published var sidebarTransparencyEnabled: Bool {
    didSet { defaults.set(sidebarTransparencyEnabled, forKey: Key.sidebarTransparencyEnabled) }
  }

  @Published var sidebarTransparency: Double {
    didSet { defaults.set(sidebarTransparency, forKey: Key.sidebarTransparency) }
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

  var activeTheme: ThemePalette {
    ThemePalette.builtIns.first(where: { $0.id == themeID }) ?? ThemePalette.system
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .english
    appearance = AppAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    sidebarTransparencyEnabled =
      defaults.object(forKey: Key.sidebarTransparencyEnabled) == nil
      ? true : defaults.bool(forKey: Key.sidebarTransparencyEnabled)
    if defaults.object(forKey: Key.sidebarTransparency) == nil {
      sidebarTransparency = 0.7
    } else {
      sidebarTransparency = min(1, max(0, defaults.double(forKey: Key.sidebarTransparency)))
    }

    let savedInterval = defaults.double(forKey: Key.refreshInterval)
    if !defaults.bool(forKey: Key.refreshIntervalDefault2Applied), savedInterval == 1 {
      refreshInterval = 2
      defaults.set(2, forKey: Key.refreshInterval)
    } else {
      refreshInterval = [0.5, 1, 2, 5].contains(savedInterval) ? savedInterval : 2
    }
    defaults.set(true, forKey: Key.refreshIntervalDefault2Applied)
    let savedLimit = defaults.integer(forKey: Key.processLimit)
    if !defaults.bool(forKey: Key.processLimitDefault20Applied), savedLimit == 5 {
      processLimit = 20
      defaults.set(20, forKey: Key.processLimit)
    } else {
      processLimit = [5, 10, 20, 50].contains(savedLimit) ? savedLimit : 20
    }
    defaults.set(true, forKey: Key.processLimitDefault20Applied)
    temperatureUnit =
      TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius

    let savedThemeID = defaults.string(forKey: Key.themeID) ?? ThemePalette.system.id
    themeID = ThemePalette.builtIns.contains(where: { $0.id == savedThemeID })
      ? savedThemeID : ThemePalette.system.id
    defaults.removeObject(forKey: "native.customTheme")

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

  func resetAll() {
    language = .english
    appearance = .system
    sidebarTransparencyEnabled = true
    sidebarTransparency = 0.7
    refreshInterval = 2
    processLimit = 20
    temperatureUnit = .celsius
    themeID = ThemePalette.system.id
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
