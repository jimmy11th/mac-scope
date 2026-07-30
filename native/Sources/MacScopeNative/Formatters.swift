import Foundation

enum DisplayFormat {
  static func bytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
  }

  static func rate(_ value: Double) -> String {
    guard value.isFinite, value > 0 else { return "0 B/s" }
    return "\(ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file))/s"
  }

  static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", max(0, value))
  }

  static func temperature(_ celsius: Double?, unit: TemperatureUnit) -> String? {
    guard let celsius, celsius.isFinite else { return nil }
    switch unit {
    case .celsius:
      return String(format: "%.0f°C", celsius)
    case .fahrenheit:
      return String(format: "%.0f°F", celsius * 9 / 5 + 32)
    }
  }

  static func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value))
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 {
      return "\(days)d \(hours)h"
    }
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  static func processState(_ value: String) -> String {
    switch value.first {
    case "R": "Running"
    case "S": "Sleeping"
    case "I": "Idle"
    case "T": "Stopped"
    case "Z": "Zombie"
    case "U": "Waiting"
    default: "Unknown"
    }
  }
}
