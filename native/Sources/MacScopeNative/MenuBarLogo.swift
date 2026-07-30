import SwiftUI

struct MenuBarLogo: View {
  var color: Color = .primary

  var body: some View {
    Canvas { context, size in
      let minimum = min(size.width, size.height)
      let lineWidth = max(1.4, minimum * 0.105)
      let bounds = CGRect(
        x: (size.width - minimum) / 2 + lineWidth / 2,
        y: (size.height - minimum) / 2 + lineWidth / 2,
        width: minimum - lineWidth,
        height: minimum - lineWidth
      )

      context.stroke(
        Path(ellipseIn: bounds),
        with: .color(color),
        style: StrokeStyle(lineWidth: lineWidth)
      )

      let points: [CGPoint] = [
        CGPoint(x: 0.14, y: 0.54),
        CGPoint(x: 0.28, y: 0.54),
        CGPoint(x: 0.36, y: 0.39),
        CGPoint(x: 0.45, y: 0.71),
        CGPoint(x: 0.55, y: 0.27),
        CGPoint(x: 0.64, y: 0.59),
        CGPoint(x: 0.72, y: 0.46),
        CGPoint(x: 0.86, y: 0.46),
      ]
      var waveform = Path()
      for (index, point) in points.enumerated() {
        let scaled = CGPoint(x: point.x * size.width, y: point.y * size.height)
        if index == 0 {
          waveform.move(to: scaled)
        } else {
          waveform.addLine(to: scaled)
        }
      }
      context.stroke(
        waveform,
        with: .color(color),
        style: StrokeStyle(
          lineWidth: lineWidth,
          lineCap: .round,
          lineJoin: .round
        )
      )
    }
    .accessibilityHidden(true)
  }
}

struct MenuBarStatusLabel: View {
  @EnvironmentObject private var metrics: SystemMetricsStore
  @EnvironmentObject private var settings: AppSettings

  var body: some View {
    MenuBarStatusContent(
      snapshot: metrics.snapshot,
      displayMode: settings.menuBarDisplayMode,
      selectedMetrics: settings.menuBarMetrics,
      temperatureUnit: settings.temperatureUnit
    )
  }
}

struct MenuBarStatusContent: View {
  let snapshot: SystemSnapshot
  let displayMode: MenuBarDisplayMode
  let selectedMetrics: [MenuBarMetric]
  let temperatureUnit: TemperatureUnit

  var body: some View {
    HStack(spacing: 5) {
      MenuBarLogo()
        .frame(width: 17, height: 17)

      if displayMode == .compact {
        ForEach(Array(selectedMetrics.enumerated()), id: \.element.id) { index, metric in
          if index > 0 {
            Text("·")
              .foregroundStyle(.tertiary)
          }
          Text(value(for: metric))
            .monospacedDigit()
        }
      }
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityValue)
  }

  private func value(for metric: MenuBarMetric) -> String {
    switch metric {
    case .cpu:
      return "CPU \(DisplayFormat.compactPercent(snapshot.cpu.total))"
    case .memory:
      return "MEM \(DisplayFormat.compactPercent(snapshot.memory.fraction * 100))"
    case .disk:
      return
        "D↓\(DisplayFormat.compactRate(snapshot.disk.readRate)) ↑\(DisplayFormat.compactRate(snapshot.disk.writeRate))"
    case .network:
      return
        "N↓\(DisplayFormat.compactRate(snapshot.network.downloadRate)) ↑\(DisplayFormat.compactRate(snapshot.network.uploadRate))"
    case .temperature:
      return DisplayFormat.temperature(
        snapshot.cpu.temperature.socCelsius,
        unit: temperatureUnit
      ) ?? "--°"
    }
  }

  private var accessibilityValue: String {
    guard displayMode == .compact, !selectedMetrics.isEmpty else { return "MacScope" }
    return selectedMetrics.map { metric in
      "\(metric.title), \(value(for: metric))"
    }.joined(separator: ", ")
  }
}
