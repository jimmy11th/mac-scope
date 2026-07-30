import Foundation

struct CPUUsage: Sendable {
  var total: Double
  var user: Double
  var system: Double
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
  let name: String
  let cpuPercent: Double
  let memoryBytes: UInt64
  let threadCount: Int
  let runtime: TimeInterval

  var id: Int32 { pid }
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
    cpu: CPUUsage(total: 0, user: 0, system: 0),
    memory: MemoryUsage(used: 0, available: 0, total: 0),
    disk: DiskUsage(used: 0, available: 0, total: 0, readRate: 0, writeRate: 0),
    network: NetworkUsage(downloadRate: 0, uploadRate: 0, downloadTotal: 0, uploadTotal: 0),
    processes: []
  )
}
