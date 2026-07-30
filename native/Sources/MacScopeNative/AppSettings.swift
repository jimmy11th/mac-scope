import Combine
import Foundation

enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
  case celsius
  case fahrenheit

  var id: String { rawValue }
}

@MainActor
final class AppSettings: ObservableObject {
  private enum Key {
    static let refreshInterval = "native.refreshInterval"
    static let processLimit = "native.processLimit"
    static let temperatureUnit = "native.temperatureUnit"
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

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let savedInterval = defaults.double(forKey: Key.refreshInterval)
    refreshInterval = [0.5, 1, 2, 5].contains(savedInterval) ? savedInterval : 1
    let savedLimit = defaults.integer(forKey: Key.processLimit)
    processLimit = [5, 10, 20, 50].contains(savedLimit) ? savedLimit : 5
    temperatureUnit =
      TemperatureUnit(rawValue: defaults.string(forKey: Key.temperatureUnit) ?? "") ?? .celsius
  }
}
