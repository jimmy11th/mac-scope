import Foundation

enum ThermalStatus: String, Sendable {
  case unavailable
  case normal
  case warm
  case hot
}

struct TemperatureUsage: Sendable {
  var socCelsius: Double?
  var batteryCelsius: Double?
  var storageCelsius: Double?
  var status: ThermalStatus

  static let unavailable = TemperatureUsage(
    socCelsius: nil,
    batteryCelsius: nil,
    storageCelsius: nil,
    status: .unavailable
  )
}

struct CPUUsage: Sendable {
  var total: Double
  var user: Double
  var system: Double
  var temperature: TemperatureUsage
}

struct MemoryUsage: Sendable {
  var used: UInt64
  var available: UInt64
  var total: UInt64

  var fraction: Double {
    total == 0 ? 0 : Double(used) / Double(total)
  }
}

struct DiskUsage: Sendable {
  var used: UInt64
  var available: UInt64
  var total: UInt64
  var readRate: Double
  var writeRate: Double

  var fraction: Double {
    total == 0 ? 0 : Double(used) / Double(total)
  }
}

struct NetworkUsage: Sendable {
  var downloadRate: Double
  var uploadRate: Double
  var downloadTotal: UInt64
  var uploadTotal: UInt64
}

struct ProcessRow: Identifiable, Hashable, Sendable {
  let pid: Int32
  let parentPID: Int32
  let name: String
  let user: String
  let state: String
  let executablePath: String
  let cpuPercent: Double
  let memoryBytes: UInt64
  let diskReadRate: Double
  let diskWriteRate: Double
  let diskReadTotal: UInt64
  let diskWriteTotal: UInt64
  let networkDownloadRate: Double
  let networkUploadRate: Double
  let networkDownloadTotal: UInt64
  let networkUploadTotal: UInt64
  let threadCount: Int
  let runtime: TimeInterval

  var id: Int32 { pid }
}

struct ProcessHistoryPoint: Identifiable, Sendable {
  let timestamp: Date
  let cpuPercent: Double
  let memoryBytes: UInt64
  let diskRate: Double
  let networkRate: Double

  var id: Date { timestamp }
}

struct SystemSnapshot: Sendable {
  var timestamp: Date
  var cpu: CPUUsage
  var memory: MemoryUsage
  var disk: DiskUsage
  var network: NetworkUsage
  var processes: [ProcessRow]

  static let empty = SystemSnapshot(
    timestamp: .now,
    cpu: CPUUsage(total: 0, user: 0, system: 0, temperature: .unavailable),
    memory: MemoryUsage(used: 0, available: 0, total: 0),
    disk: DiskUsage(used: 0, available: 0, total: 0, readRate: 0, writeRate: 0),
    network: NetworkUsage(downloadRate: 0, uploadRate: 0, downloadTotal: 0, uploadTotal: 0),
    processes: []
  )
}
