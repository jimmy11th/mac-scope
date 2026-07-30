import Darwin
import Foundation
import IOKit

private struct CPUTicks {
  var user: UInt64
  var system: UInt64
  var idle: UInt64
}

private struct ByteCounters {
  var read: UInt64
  var written: UInt64
}

actor SystemSampler {
  private var previousCPU: CPUTicks?
  private var previousDisk: ByteCounters?
  private var previousNetwork: ByteCounters?
  private var previousTime = ProcessInfo.processInfo.systemUptime

  func sample() -> SystemSnapshot {
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(0.001, now - previousTime)
    let cpuTicks = readCPUTicks()
    let diskCounters = readDiskCounters()
    let networkCounters = readNetworkCounters()
    let cpu = calculateCPU(current: cpuTicks, previous: previousCPU)
    let memory = readMemoryUsage()
    let diskCapacity = readDiskCapacity()
    let disk = DiskUsage(
      used: diskCapacity.used,
      available: diskCapacity.available,
      total: diskCapacity.total,
      readRate: rate(current: diskCounters.read, previous: previousDisk?.read, elapsed: elapsed),
      writeRate: rate(
        current: diskCounters.written,
        previous: previousDisk?.written,
        elapsed: elapsed
      )
    )
    let network = NetworkUsage(
      downloadRate: rate(
        current: networkCounters.read,
        previous: previousNetwork?.read,
        elapsed: elapsed
      ),
      uploadRate: rate(
        current: networkCounters.written,
        previous: previousNetwork?.written,
        elapsed: elapsed
      ),
      downloadTotal: networkCounters.read,
      uploadTotal: networkCounters.written
    )

    previousCPU = cpuTicks
    previousDisk = diskCounters
    previousNetwork = networkCounters
    previousTime = now

    return SystemSnapshot(
      timestamp: .now,
      cpu: cpu,
      memory: memory,
      disk: disk,
      network: network,
      processes: readProcesses()
    )
  }

  private func readCPUTicks() -> CPUTicks {
    var cpuCount: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    let result = host_processor_info(
      mach_host_self(),
      PROCESSOR_CPU_LOAD_INFO,
      &cpuCount,
      &cpuInfo,
      &infoCount
    )
    guard result == KERN_SUCCESS, let cpuInfo else {
      return CPUTicks(user: 0, system: 0, idle: 0)
    }
    defer {
      let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
      vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
    }

    let values = UnsafeBufferPointer(start: cpuInfo, count: Int(infoCount))
    var ticks = CPUTicks(user: 0, system: 0, idle: 0)
    for cpu in 0..<Int(cpuCount) {
      let base = cpu * Int(CPU_STATE_MAX)
      ticks.user += UInt64(values[base + Int(CPU_STATE_USER)])
      ticks.user += UInt64(values[base + Int(CPU_STATE_NICE)])
      ticks.system += UInt64(values[base + Int(CPU_STATE_SYSTEM)])
      ticks.idle += UInt64(values[base + Int(CPU_STATE_IDLE)])
    }
    return ticks
  }

  private func calculateCPU(current: CPUTicks, previous: CPUTicks?) -> CPUUsage {
    guard let previous else {
      return CPUUsage(total: 0, user: 0, system: 0)
    }
    let user = current.user >= previous.user ? current.user - previous.user : 0
    let system = current.system >= previous.system ? current.system - previous.system : 0
    let idle = current.idle >= previous.idle ? current.idle - previous.idle : 0
    let total = max(1, user + system + idle)
    let userPercent = Double(user) / Double(total) * 100
    let systemPercent = Double(system) / Double(total) * 100
    return CPUUsage(
      total: userPercent + systemPercent,
      user: userPercent,
      system: systemPercent
    )
  }

  private func readMemoryUsage() -> MemoryUsage {
    var statistics = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &statistics) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
      }
    }
    guard result == KERN_SUCCESS else {
      return MemoryUsage(used: 0, available: 0, total: ProcessInfo.processInfo.physicalMemory)
    }
    var pageSize: vm_size_t = 0
    host_page_size(mach_host_self(), &pageSize)
    let availablePages =
      UInt64(statistics.free_count)
      + UInt64(statistics.inactive_count)
      + UInt64(statistics.speculative_count)
    let total = ProcessInfo.processInfo.physicalMemory
    let available = min(total, availablePages * UInt64(pageSize))
    return MemoryUsage(used: total - available, available: available, total: total)
  }

  private func readDiskCapacity() -> (used: UInt64, available: UInt64, total: UInt64) {
    let keys: Set<URLResourceKey> = [
      .volumeTotalCapacityKey,
      .volumeAvailableCapacityForImportantUsageKey,
    ]
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else {
      return (0, 0, 0)
    }
    let total = UInt64(max(0, values.volumeTotalCapacity ?? 0))
    let available = UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0))
    return (total - min(total, available), available, total)
  }

  private func readDiskCounters() -> ByteCounters {
    var iterator: io_iterator_t = 0
    guard
      let matching = IOServiceMatching("IOBlockStorageDriver"),
      IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
    else {
      return ByteCounters(read: 0, written: 0)
    }
    defer { IOObjectRelease(iterator) }

    var counters = ByteCounters(read: 0, written: 0)
    var service = IOIteratorNext(iterator)
    while service != 0 {
      if let value = IORegistryEntryCreateCFProperty(
        service,
        "Statistics" as CFString,
        kCFAllocatorDefault,
        0
      )?.takeRetainedValue(),
        let statistics = value as? [String: Any]
      {
        counters.read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
        counters.written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
      }
      IOObjectRelease(service)
      service = IOIteratorNext(iterator)
    }
    return counters
  }

  private func readNetworkCounters() -> ByteCounters {
    var addressList: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
      return ByteCounters(read: 0, written: 0)
    }
    defer { freeifaddrs(addressList) }

    var counters = ByteCounters(read: 0, written: 0)
    var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let address = pointer?.pointee {
      defer { pointer = address.ifa_next }
      guard address.ifa_addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
      let flags = Int32(address.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
      let name = String(cString: address.ifa_name)
      guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("utun") else {
        continue
      }
      guard let rawData = address.ifa_data else { continue }
      let data = rawData.assumingMemoryBound(to: if_data.self).pointee
      counters.read += UInt64(data.ifi_ibytes)
      counters.written += UInt64(data.ifi_obytes)
    }
    return counters
  }

  private func readProcesses() -> [ProcessRow] {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,pcpu=,rss=,etime=,comm="]
    process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return []
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
      return []
    }

    let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
    return text.split(separator: "\n").compactMap { line in
      let fields = line.split(
        maxSplits: 4,
        omittingEmptySubsequences: true,
        whereSeparator: { $0 == " " || $0 == "\t" }
      )
      guard
        fields.count == 5,
        let pid = Int32(fields[0]),
        pid != ownPID,
        let cpu = Double(fields[1]),
        let residentKilobytes = UInt64(fields[2])
      else {
        return nil
      }
      let command = String(fields[4])
      let filename = URL(fileURLWithPath: command).lastPathComponent
      return ProcessRow(
        pid: pid,
        name: filename.isEmpty ? command : filename,
        cpuPercent: max(0, cpu),
        memoryBytes: residentKilobytes * 1_024,
        threadCount: readThreadCount(pid: pid),
        runtime: parseElapsed(String(fields[3]))
      )
    }
  }

  private func readThreadCount(pid: Int32) -> Int {
    var information = proc_taskinfo()
    let size = Int32(MemoryLayout<proc_taskinfo>.size)
    let result = withUnsafeMutablePointer(to: &information) { pointer in
      proc_pidinfo(pid, PROC_PIDTASKINFO, 0, pointer, size)
    }
    return result == size ? max(0, Int(information.pti_threadnum)) : 0
  }

  private func parseElapsed(_ value: String) -> TimeInterval {
    let dayParts = value.split(separator: "-", maxSplits: 1).map(String.init)
    let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
    let clock = dayParts.last?.split(separator: ":").compactMap { Double($0) } ?? []
    switch clock.count {
    case 3:
      return days * 86_400 + clock[0] * 3_600 + clock[1] * 60 + clock[2]
    case 2:
      return days * 86_400 + clock[0] * 60 + clock[1]
    case 1:
      return days * 86_400 + clock[0]
    default:
      return days * 86_400
    }
  }

  private func rate(current: UInt64, previous: UInt64?, elapsed: TimeInterval) -> Double {
    guard let previous, current >= previous else { return 0 }
    return Double(current - previous) / elapsed
  }
}
