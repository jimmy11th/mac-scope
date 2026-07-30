import SwiftUI

enum MetricColorScale {
  static func utilization(fraction: Double) -> Color {
    switch min(1, max(0, fraction)) {
    case ...0.30: .green
    case ...0.50: .blue
    case ...0.70: .yellow
    case ...0.90: .orange
    default: .red
    }
  }

  static func network(rate: Double) -> Color {
    switch max(0, rate) {
    case ..<(10 * 1_024): .red
    case ..<(500 * 1_024): .orange
    case ..<(3 * 1_024 * 1_024): .yellow
    case ..<(10 * 1_024 * 1_024): .blue
    default: .green
    }
  }

  static func temperature(celsius: Double?) -> Color {
    guard let celsius else { return .secondary }
    return switch celsius {
    case ..<(-20): .red
    case ..<(-10): .orange
    case ..<0: .yellow
    case ..<10: .blue
    case ..<30: .green
    case ..<50: .blue
    case ..<70: .yellow
    case ..<90: .orange
    default: .red
    }
  }
}
