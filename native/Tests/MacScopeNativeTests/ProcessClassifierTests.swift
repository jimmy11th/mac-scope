import Foundation
import Testing

@testable import MacScopeNative

@Suite("Process classification")
struct ProcessClassifierTests {
  @Test("Protected macOS paths are system software")
  func classifiesSystemPaths() {
    let identity = ProcessClassifier.classify(
      executablePath: "/usr/libexec/logd",
      command: "/usr/libexec/logd"
    )

    #expect(identity.origin == .macOSSystem)
    #expect(identity.name == "logd")
  }

  @Test("The writable data volume is not treated as a system path")
  func classifiesDataVolumeApplications() {
    let identity = ProcessClassifier.classify(
      executablePath: "/System/Volumes/Data/Applications/Example.app/Contents/MacOS/Example",
      command: "Example"
    )

    #expect(identity.origin == .installedSoftware)
    #expect(identity.name == "Example")
  }

  @Test("Nested helpers belong to the outermost application")
  func groupsNestedApplicationHelpers() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let application = root.appendingPathComponent("Example.app", isDirectory: true)
    let contents = application.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "com.example.Example",
      "CFBundleName": "Example Product",
    ]
    let plist = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try plist.write(to: contents.appendingPathComponent("Info.plist"))

    let helper = application.appendingPathComponent(
      "Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper"
    )
    let identity = ProcessClassifier.classify(
      executablePath: helper.path,
      command: "Example Helper",
      homeDirectory: root.appendingPathComponent("Home", isDirectory: true)
    )

    #expect(identity.origin == .installedSoftware)
    #expect(identity.bundleIdentifier == "com.example.Example")
    #expect(identity.name == "Example Product")
    #expect(identity.bundleURL == application.standardizedFileURL)
    #expect(identity.id == "application:\(application.standardizedFileURL.path)")
  }

  @Test("Home directory executables are user tools")
  func classifiesUserTools() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let identity = ProcessClassifier.classify(
      executablePath: "/Users/example/.local/bin/server",
      command: "server",
      homeDirectory: home
    )

    #expect(identity.origin == .userTool)
  }

  @Test("Pathless processes remain unidentified")
  func preservesUnknownProcesses() {
    let identity = ProcessClassifier.classify(
      executablePath: "restricted-service",
      command: "restricted-service"
    )

    #expect(identity.origin == .unknown)
    #expect(identity.name == "restricted-service")
  }
}

@Suite("Software process grouping")
struct SoftwareProcessGroupingTests {
  @Test("Processes with one software identity aggregate together")
  func aggregatesSoftwareResources() throws {
    let software = SoftwareIdentity(
      id: "bundle:com.example.Example",
      name: "Example",
      bundleIdentifier: "com.example.Example",
      bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
      origin: .installedSoftware
    )
    let processes = [
      process(pid: 101, cpu: 12.5, memory: 1_024, disk: 300, network: 500, software: software),
      process(pid: 102, cpu: 7.5, memory: 2_048, disk: 700, network: 1_500, software: software),
    ]

    let group = try #require(SoftwareProcessGroup.groups(from: processes).first)
    #expect(group.processes.map(\.pid) == [101, 102])
    #expect(group.cpuPercent == 20)
    #expect(group.memoryBytes == 3_072)
    #expect(group.diskRate == 1_000)
    #expect(group.networkRate == 2_000)
  }

  @Test("Expanded processes follow the selected software column")
  func sortsExpandedProcesses() {
    let software = SoftwareIdentity(
      id: "application:/Applications/Example.app",
      name: "Example",
      bundleIdentifier: "com.example.Example",
      bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
      origin: .installedSoftware
    )
    let processes = [
      process(
        pid: 302,
        cpu: 30,
        memory: 100,
        disk: 500,
        network: 900,
        software: software,
        name: "Zulu"
      ),
      process(
        pid: 101,
        cpu: 20,
        memory: 200,
        disk: 900,
        network: 100,
        software: software,
        name: "Beta"
      ),
      process(
        pid: 203,
        cpu: 10,
        memory: 300,
        disk: 100,
        network: 500,
        software: software,
        name: "Alpha"
      ),
    ]

    func pids(_ field: SoftwareSortField, _ direction: SoftwareSortDirection) -> [Int32] {
      SoftwareSortDescriptor(field: field, direction: direction)
        .sorted(processes: processes)
        .map(\.pid)
    }

    #expect(pids(.name, .ascending) == [203, 101, 302])
    #expect(pids(.processCount, .ascending) == [101, 203, 302])
    #expect(pids(.cpu, .descending) == [302, 101, 203])
    #expect(pids(.memory, .descending) == [203, 101, 302])
    #expect(pids(.disk, .descending) == [101, 302, 203])
    #expect(pids(.network, .descending) == [302, 203, 101])
  }

  @Test("Selecting headers applies conventional default directions")
  func selectsSoftwareSortDirection() {
    var sort = SoftwareSortDescriptor.initial

    sort.select(.memory)
    #expect(sort == SoftwareSortDescriptor(field: .memory, direction: .descending))

    sort.select(.memory)
    #expect(sort == SoftwareSortDescriptor(field: .memory, direction: .ascending))

    sort.select(.name)
    #expect(sort == SoftwareSortDescriptor(field: .name, direction: .ascending))
  }

  @Test("Software groups sort by aggregate values")
  func sortsSoftwareGroups() {
    let alpha = SoftwareIdentity(
      id: "application:/Applications/Alpha.app",
      name: "Alpha",
      bundleIdentifier: "com.example.Alpha",
      bundleURL: URL(fileURLWithPath: "/Applications/Alpha.app"),
      origin: .installedSoftware
    )
    let beta = SoftwareIdentity(
      id: "application:/Applications/Beta.app",
      name: "Beta",
      bundleIdentifier: "com.example.Beta",
      bundleURL: URL(fileURLWithPath: "/Applications/Beta.app"),
      origin: .installedSoftware
    )
    let groups = SoftwareProcessGroup.groups(from: [
      process(pid: 101, cpu: 50, memory: 100, disk: 0, network: 0, software: alpha),
      process(pid: 201, cpu: 10, memory: 100, disk: 0, network: 0, software: beta),
      process(pid: 202, cpu: 10, memory: 100, disk: 0, network: 0, software: beta),
    ])

    let byCPU = SoftwareSortDescriptor(field: .cpu, direction: .descending)
      .sorted(groups: groups)
      .map(\.software.name)
    let byProcessCount = SoftwareSortDescriptor(field: .processCount, direction: .descending)
      .sorted(groups: groups)
      .map(\.software.name)

    #expect(byCPU == ["Alpha", "Beta"])
    #expect(byProcessCount == ["Beta", "Alpha"])
  }

  private func process(
    pid: Int32,
    cpu: Double,
    memory: UInt64,
    disk: Double,
    network: Double,
    software: SoftwareIdentity,
    name: String = "Example Helper"
  ) -> ProcessRow {
    ProcessRow(
      pid: pid,
      parentPID: 1,
      name: name,
      user: "example",
      state: "S",
      executablePath: "/Applications/Example.app/Contents/MacOS/Example",
      cpuPercent: cpu,
      memoryBytes: memory,
      diskReadRate: disk / 2,
      diskWriteRate: disk / 2,
      diskReadTotal: 0,
      diskWriteTotal: 0,
      networkDownloadRate: network / 2,
      networkUploadRate: network / 2,
      networkDownloadTotal: 0,
      networkUploadTotal: 0,
      threadCount: 1,
      runtime: 60,
      software: software
    )
  }
}
