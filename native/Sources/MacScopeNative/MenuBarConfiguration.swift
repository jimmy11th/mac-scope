import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
  case iconOnly
  case compact

  var id: String { rawValue }
}

enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network
  case temperature

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU Usage"
    case .memory: "Memory Usage"
    case .disk: "Disk Activity"
    case .network: "Network Activity"
    case .temperature: "CPU Temperature"
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    case .temperature: "thermometer.medium"
    }
  }
}

enum MenuBarModule: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network
  case temperature
  case processes

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    case .temperature: "Temperature"
    case .processes: "Top Processes"
    }
  }

  var systemImage: String {
    switch self {
    case .cpu: "cpu"
    case .memory: "memorychip"
    case .disk: "internaldrive"
    case .network: "network"
    case .temperature: "thermometer.medium"
    case .processes: "list.number"
    }
  }
}

enum MenuBarProcessSort: String, CaseIterable, Identifiable, Sendable {
  case cpu
  case memory
  case disk
  case network

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cpu: "CPU"
    case .memory: "Memory"
    case .disk: "Disk"
    case .network: "Network"
    }
  }
}
