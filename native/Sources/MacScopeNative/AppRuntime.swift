import AppKit
import Combine

@MainActor
final class AppRuntime: ObservableObject {
  let monitor: SystemMonitor
  let settings: AppSettings
  let maintenance: MaintenanceStore
  let navigation: AppNavigation

  private var cancellables: Set<AnyCancellable> = []

  init() {
    monitor = SystemMonitor()
    settings = AppSettings()
    maintenance = MaintenanceStore()
    navigation = AppNavigation()

    let sceneSettingsChanges: [AnyPublisher<Void, Never>] = [
      settings.$language.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$appearance.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$themeID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
      settings.$menuBarEnabled.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
    ]
    Publishers.MergeMany(sceneSettingsChanges)
      .sink { [weak self] in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    settings.$refreshInterval
      .removeDuplicates()
      .dropFirst()
      .sink { [weak monitor] interval in
        Task { @MainActor in
          monitor?.updateRefreshInterval(interval)
        }
      }
      .store(in: &cancellables)

    settings.$language
      .removeDuplicates()
      .dropFirst()
      .sink { [weak maintenance] language in
        Task { @MainActor in
          maintenance?.updateLanguage(language)
        }
      }
      .store(in: &cancellables)

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.monitor.updateRefreshInterval(self.settings.refreshInterval)
      self.monitor.start()
      self.maintenance.updateLanguage(self.settings.language)
      AppIconController.apply(self.settings.appIconStyle)
    }
  }
}
