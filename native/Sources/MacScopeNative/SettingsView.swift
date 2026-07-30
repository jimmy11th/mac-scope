import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    Form {
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
}
