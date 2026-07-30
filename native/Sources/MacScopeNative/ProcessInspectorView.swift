import AppKit
import Charts
import SwiftUI

struct ProcessInspectorView: View {
  let process: ProcessRow
  let history: [ProcessHistoryPoint]
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          activitySection
          cpuChart
          memoryChart
          ioChart
          generalSection
        }
        .padding(16)
      }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(nsImage: processIcon)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: 40, height: 40)
      VStack(alignment: .leading, spacing: 2) {
        Text(process.name)
          .font(.headline)
          .lineLimit(1)
        Text("PID \(process.pid) · \(process.user)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Button(action: onClose) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .help("Close Process Info")
    }
    .padding(16)
  }

  private var activitySection: some View {
    InspectorSection(title: "Activity") {
      LabeledContent("CPU") {
        Text(DisplayFormat.percent(process.cpuPercent))
      }
      LabeledContent("Memory") {
        Text(DisplayFormat.bytes(process.memoryBytes))
      }
      LabeledContent("Disk read") {
        Text(DisplayFormat.rate(process.diskReadRate))
      }
      LabeledContent("Disk write") {
        Text(DisplayFormat.rate(process.diskWriteRate))
      }
      LabeledContent("Download") {
        Text(DisplayFormat.rate(process.networkDownloadRate))
      }
      LabeledContent("Upload") {
        Text(DisplayFormat.rate(process.networkUploadRate))
      }
    }
    .monospacedDigit()
  }

  private var cpuChart: some View {
    InspectorSection(title: "CPU · Last 60 Seconds") {
      Chart(history) { point in
        AreaMark(
          x: .value("Time", point.timestamp),
          y: .value("CPU", point.cpuPercent)
        )
        .foregroundStyle(.blue.opacity(0.12))
        LineMark(
          x: .value("Time", point.timestamp),
          y: .value("CPU", point.cpuPercent)
        )
        .foregroundStyle(.blue)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
      }
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let percent = value.as(Double.self) {
              Text("\(percent, specifier: "%.0f")%")
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var ioChart: some View {
    InspectorSection(title: "I/O · Last 60 Seconds") {
      HStack(spacing: 12) {
        ChartLegend(color: .orange, title: "Disk")
        ChartLegend(color: .pink, title: "Network")
      }
      Chart {
        ForEach(history) { point in
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Disk", point.diskRate)
          )
          .foregroundStyle(.orange)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
          LineMark(
            x: .value("Time", point.timestamp),
            y: .value("Network", point.networkRate)
          )
          .foregroundStyle(.pink)
          .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
      }
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let rate = value.as(Double.self) {
              Text(DisplayFormat.rate(rate))
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var memoryChart: some View {
    InspectorSection(title: "Memory · Last 60 Seconds") {
      Chart(history) { point in
        AreaMark(
          x: .value("Time", point.timestamp),
          y: .value("Memory", Double(point.memoryBytes))
        )
        .foregroundStyle(.green.opacity(0.12))
        LineMark(
          x: .value("Time", point.timestamp),
          y: .value("Memory", Double(point.memoryBytes))
        )
        .foregroundStyle(.green)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
      }
      .chartXAxis(.hidden)
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
          AxisGridLine()
          AxisValueLabel {
            if let bytes = value.as(Double.self) {
              Text(DisplayFormat.bytes(UInt64(max(0, bytes))))
            }
          }
        }
      }
      .frame(height: 92)
    }
  }

  private var generalSection: some View {
    InspectorSection(title: "General") {
      LabeledContent("State", value: DisplayFormat.processState(process.state))
      LabeledContent("Parent PID", value: String(process.parentPID))
      LabeledContent("Threads", value: String(process.threadCount))
      LabeledContent("Runtime", value: DisplayFormat.duration(process.runtime))
      LabeledContent("Disk read total", value: DisplayFormat.bytes(process.diskReadTotal))
      LabeledContent("Disk write total", value: DisplayFormat.bytes(process.diskWriteTotal))
      LabeledContent("Downloaded", value: DisplayFormat.bytes(process.networkDownloadTotal))
      LabeledContent("Uploaded", value: DisplayFormat.bytes(process.networkUploadTotal))
      VStack(alignment: .leading, spacing: 4) {
        Text("Executable")
          .foregroundStyle(.secondary)
        Text(process.executablePath)
          .font(.caption)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var processIcon: NSImage {
    let iconPath: String
    if let appRange = process.executablePath.range(of: ".app/", options: .caseInsensitive) {
      iconPath = String(
        process.executablePath[..<process.executablePath.index(before: appRange.upperBound)])
    } else {
      iconPath = process.executablePath
    }
    guard FileManager.default.fileExists(atPath: iconPath) else {
      return NSImage(
        systemSymbolName: "gearshape.2",
        accessibilityDescription: "Process"
      ) ?? NSImage()
    }
    return NSWorkspace.shared.icon(forFile: iconPath)
  }
}

private struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.subheadline.weight(.semibold))
      content
    }
  }
}

private struct ChartLegend: View {
  let color: Color
  let title: String

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
