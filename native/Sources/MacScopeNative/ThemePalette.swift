import AppKit
import Foundation
import SwiftUI

struct ThemePalette: Codable, Hashable, Identifiable, Sendable {
  var id: String
  var name: String
  var accentHex: String
  var cpuHex: String
  var memoryHex: String
  var diskHex: String
  var networkHex: String

  static let system = ThemePalette(
    id: "system",
    name: "System",
    accentHex: "#0A84FF",
    cpuHex: "#0A84FF",
    memoryHex: "#30D158",
    diskHex: "#FF9F0A",
    networkHex: "#FF375F"
  )

  static let graphite = ThemePalette(
    id: "graphite",
    name: "Graphite",
    accentHex: "#73777F",
    cpuHex: "#5E5CE6",
    memoryHex: "#32ADE6",
    diskHex: "#FF9F0A",
    networkHex: "#FF375F"
  )

  static let highContrast = ThemePalette(
    id: "high-contrast",
    name: "High Contrast",
    accentHex: "#0057D9",
    cpuHex: "#0057D9",
    memoryHex: "#008A3B",
    diskHex: "#B25000",
    networkHex: "#C40030"
  )

  static let builtIns = [system, graphite, highContrast]

  var accentColor: Color { Color(hex: accentHex) }
  var cpuColor: Color { Color(hex: cpuHex) }
  var memoryColor: Color { Color(hex: memoryHex) }
  var diskColor: Color { Color(hex: diskHex) }
  var networkColor: Color { Color(hex: networkHex) }

  var isValid: Bool {
    let pattern = /^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/
    return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && [accentHex, cpuHex, memoryHex, diskHex, networkHex].allSatisfy {
        $0.wholeMatch(of: pattern) != nil
      }
  }
}

extension Color {
  init(hex: String) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    let value = UInt64(cleaned, radix: 16) ?? 0
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double
    switch cleaned.count {
    case 8:
      red = Double((value >> 24) & 0xFF) / 255
      green = Double((value >> 16) & 0xFF) / 255
      blue = Double((value >> 8) & 0xFF) / 255
      alpha = Double(value & 0xFF) / 255
    default:
      red = Double((value >> 16) & 0xFF) / 255
      green = Double((value >> 8) & 0xFF) / 255
      blue = Double(value & 0xFF) / 255
      alpha = 1
    }
    self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
  }

  var hexString: String {
    guard let color = NSColor(self).usingColorSpace(.sRGB) else { return "#0A84FF" }
    return String(
      format: "#%02X%02X%02X",
      Int(round(color.redComponent * 255)),
      Int(round(color.greenComponent * 255)),
      Int(round(color.blueComponent * 255))
    )
  }
}

extension AppAppearance {
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
