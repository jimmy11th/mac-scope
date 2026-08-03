import AppKit
import CryptoKit
import Foundation

actor MaintenanceService {
  typealias ScanReporter = @Sendable (ScanProgress) async -> Void
  typealias CleanupReporter = @Sendable (CleanupProgress) async -> Void

  private let fileManager = FileManager.default
  private let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL

  func scanJunk(progress: ScanReporter) async throws -> ScanResult<MaintenanceItem> {
    let library = home.appendingPathComponent("Library", isDirectory: true)
    let definitions: [(URL, MaintenanceItemKind, String)] = [
      (library.appendingPathComponent("Caches"), .cache, "Caches"),
      (library.appendingPathComponent("Logs"), .log, "Logs"),
      (library.appendingPathComponent("DiagnosticReports"), .diagnostic, "Diagnostics"),
      (
        library.appendingPathComponent("Developer/Xcode/DerivedData"),
        .developer,
        "Developer Files"
      ),
      (
        library.appendingPathComponent("Developer/CoreSimulator/Caches"),
        .developer,
        "Developer Files"
      ),
    ]

    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    var scanned = 0
    for (root, kind, category) in definitions where fileManager.fileExists(atPath: root.path) {
      try Task.checkCancellation()
      do {
        let children = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
        for child in children {
          try Task.checkCancellation()
          do {
            let (size, count) = try await pathSize(child)
            let identity = try fileIdentity(child)
            scanned += count
            items.append(
              makeItem(
                kind: kind,
                category: category,
                url: child,
                size: size,
                identity: identity
              ))
            await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            issues.append(Self.scanIssue(at: child, error: error, home: home))
          }
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home))
      }
    }
    items.sort { $0.size > $1.size }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanApplications(progress: ScanReporter) async throws -> ScanResult<ApplicationRecord> {
    let roots = [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      home.appendingPathComponent("Applications", isDirectory: true),
    ]
    let runningPaths = await MainActor.run {
      Set(
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
      )
    }
    let currentApplicationPath = await MainActor.run {
      Bundle.main.bundleURL.standardizedFileURL.path
    }
    var applications: [(item: MaintenanceItem, bundleID: String, version: String)] = []
    var issues: [ScanIssue] = []
    var scanned = 0

    for root in roots where fileManager.fileExists(atPath: root.path) {
      var stack: [(URL, Int)] = [(root, 0)]
      while let (directory, depth) = stack.popLast() {
        try Task.checkCancellation()
        guard depth <= 2 else { continue }
        do {
          let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
          )
          for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            if child.pathExtension.lowercased() == "app" {
              guard child.standardizedFileURL.path != currentApplicationPath else { continue }
              do {
                let (size, count) = try await pathSize(child)
                let identity = try fileIdentity(child)
                let metadata = applicationMetadata(child)
                scanned += count
                applications.append(
                  (
                    makeItem(
                      kind: .application,
                      category: "Application",
                      name: metadata.name,
                      url: child,
                      size: size,
                      identity: identity,
                      group: metadata.bundleID
                    ),
                    metadata.bundleID,
                    metadata.version
                  ))
                await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
              } catch is CancellationError {
                throw CancellationError()
              } catch {
                issues.append(Self.scanIssue(at: child, error: error, home: home))
              }
            } else if depth < 2 {
              stack.append((child, depth + 1))
            }
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(Self.scanIssue(at: directory, error: error, home: home))
        }
      }
    }

    let grouped = Dictionary(grouping: applications) { application in
      application.bundleID.isEmpty ? application.item.id : application.bundleID
    }
    var records: [ApplicationRecord] = []
    records.reserveCapacity(grouped.count)
    for group in grouped.values {
      try Task.checkCancellation()
      let orderedCopies = group.sorted { lhs, rhs in
        let lhsIsMain = lhs.item.url.path.hasPrefix("/Applications/")
        let rhsIsMain = rhs.item.url.path.hasPrefix("/Applications/")
        if lhsIsMain != rhsIsMain { return lhsIsMain }
        return lhs.item.url.path.localizedStandardCompare(rhs.item.url.path) == .orderedAscending
      }
      guard let application = orderedCopies.first else { continue }
      let residueResult = try await residueItems(
        bundleID: application.bundleID,
        parentID: application.item.id
      )
      issues.append(contentsOf: residueResult.issues)
      let copies = orderedCopies.dropFirst().map(\.item)
      let installedPaths = Set(orderedCopies.map { $0.item.url.standardizedFileURL.path })
      let isRunning = runningPaths.contains { installedPaths.contains($0) }
      records.append(
        ApplicationRecord(
          application: application.item,
          bundleIdentifier: application.bundleID,
          version: application.version,
          residues: residueResult.items,
          otherCopies: copies,
          isRunning: isRunning
        ))
    }
    records.sort {
      $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending
    }
    return ScanResult(values: records, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanLargeFiles(
    roots: [URL],
    thresholdMB: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let threshold = UInt64(thresholdMB) * 1_024 * 1_024
    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    var scanned = 0
    for root in safeScanRoots(roots) {
      do {
        _ = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home, configuredRoot: true))
        continue
      }
      let scanHome = home
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) { url, error in
        issues.append(Self.scanIssue(at: url, error: error, home: scanHome, configuredRoot: true))
        return true
      }
      while let file = enumerator?.nextObject() as? URL {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ])
        if values.isSymbolicLink == true {
          enumerator?.skipDescendants()
          continue
        }
        guard values.isRegularFile == true else { continue }
        scanned += 1
        if scanned.isMultiple(of: 100) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: file.path))
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size >= threshold else { continue }
        let identity = try fileIdentity(file)
        items.append(
          makeItem(
            kind: .largeFile,
            category: "Large File",
            url: file,
            size: size,
            identity: identity
          ))
      }
    }
    items.sort { $0.size > $1.size }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanDuplicates(
    roots: [URL],
    minimumMB: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let minimum = UInt64(minimumMB) * 1_024 * 1_024
    var bySize: [UInt64: [URL]] = [:]
    var issues: [ScanIssue] = []
    var scanned = 0
    var identities = Set<String>()

    for root in safeScanRoots(roots) {
      do {
        _ = try fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: nil,
          options: [.skipsHiddenFiles]
        )
      } catch {
        issues.append(Self.scanIssue(at: root, error: error, home: home, configuredRoot: true))
        continue
      }
      let scanHome = home
      let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) { url, error in
        issues.append(Self.scanIssue(at: url, error: error, home: scanHome, configuredRoot: true))
        return true
      }
      while let file = enumerator?.nextObject() as? URL {
        try Task.checkCancellation()
        let values = try file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        if values.isSymbolicLink == true {
          enumerator?.skipDescendants()
          continue
        }
        guard values.isRegularFile == true else { continue }
        scanned += 1
        if scanned.isMultiple(of: 100) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: file.path))
        }
        let size = UInt64(max(0, values.fileSize ?? 0))
        guard size >= minimum else { continue }
        let identity = try fileIdentity(file)
        let identityKey = "\(identity.device):\(identity.inode)"
        guard identities.insert(identityKey).inserted else { continue }
        bySize[size, default: []].append(file)
      }
    }

    var items: [MaintenanceItem] = []
    for (size, candidates) in bySize where candidates.count > 1 {
      var byHash: [String: [URL]] = [:]
      for candidate in candidates {
        try Task.checkCancellation()
        do {
          let digest = try await hashFile(candidate)
          byHash[digest, default: []].append(candidate)
          await progress(ScanProgress(scannedCount: scanned, currentPath: candidate.path))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(
            Self.scanIssue(at: candidate, error: error, home: home, configuredRoot: true)
          )
        }
      }
      for (digest, duplicates) in byHash where duplicates.count > 1 {
        for duplicate in duplicates.sorted(by: { $0.path < $1.path }) {
          let identity = try fileIdentity(duplicate)
          items.append(
            makeItem(
              kind: .duplicate,
              category: "Duplicate",
              url: duplicate,
              size: size,
              identity: identity,
              group: String(digest.prefix(12))
            ))
        }
      }
    }
    items.sort { lhs, rhs in
      lhs.group == rhs.group ? lhs.url.path < rhs.url.path : lhs.size > rhs.size
    }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func scanDownloads(
    olderThanDays: Int,
    progress: ScanReporter
  ) async throws -> ScanResult<MaintenanceItem> {
    let root = home.appendingPathComponent("Downloads", isDirectory: true)
    var issues: [ScanIssue] = []
    let children: [URL]
    do {
      children = try fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ],
        options: [.skipsHiddenFiles]
      )
    } catch {
      let issue = Self.scanIssue(at: root, error: error, home: home, configuredRoot: true)
      return ScanResult(values: [], issues: [issue], scannedCount: 0)
    }

    var candidates: [DownloadCandidate] = []
    var scanned = 0
    for child in children {
      try Task.checkCancellation()
      do {
        let values = try child.resourceValues(forKeys: [
          .isRegularFileKey,
          .isSymbolicLinkKey,
          .fileSizeKey,
          .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let size = UInt64(max(0, values.fileSize ?? 0))
        let modified = values.contentModificationDate ?? .distantPast
        candidates.append(DownloadCandidate(url: child, size: size, modified: modified))
        scanned += 1
        if scanned.isMultiple(of: 20) {
          await progress(ScanProgress(scannedCount: scanned, currentPath: child.path))
        }
      } catch {
        issues.append(Self.scanIssue(at: child, error: error, home: home, configuredRoot: true))
      }
    }

    var duplicateHashes: [String: String] = [:]
    let candidatesBySize = Dictionary(grouping: candidates.filter { $0.size > 0 }, by: \.size)
    for sameSize in candidatesBySize.values where sameSize.count > 1 {
      var filesByHash: [String: [DownloadCandidate]] = [:]
      for candidate in sameSize {
        try Task.checkCancellation()
        do {
          let digest = try await hashFile(candidate.url)
          filesByHash[digest, default: []].append(candidate)
          await progress(ScanProgress(scannedCount: scanned, currentPath: candidate.url.path))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          issues.append(
            Self.scanIssue(at: candidate.url, error: error, home: home, configuredRoot: true)
          )
        }
      }
      for (digest, matches) in filesByHash where matches.count > 1 {
        for match in matches {
          duplicateHashes[match.url.standardizedFileURL.path] = digest
        }
      }
    }

    let cutoff = Date().addingTimeInterval(-Double(max(1, olderThanDays)) * 86_400)
    let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso"]
    let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"]
    let incompleteExtensions: Set<String> = ["download", "crdownload", "part"]
    var items: [MaintenanceItem] = []

    for candidate in candidates {
      let path = candidate.url.standardizedFileURL.path
      let fileExtension = candidate.url.pathExtension.lowercased()
      let category: String
      let group: String
      if let digest = duplicateHashes[path] {
        category = "Duplicate Download"
        group = String(digest.prefix(12))
      } else if incompleteExtensions.contains(fileExtension) {
        category = "Incomplete Download"
        group = ""
      } else if installerExtensions.contains(fileExtension) {
        category = "Installer"
        group = ""
      } else if archiveExtensions.contains(fileExtension) {
        category = "Archive"
        group = ""
      } else if candidate.size >= 1_024 * 1_024 * 1_024 {
        category = "Large Download"
        group = ""
      } else if candidate.modified < cutoff {
        category = "Old Download"
        group = ""
      } else {
        continue
      }

      do {
        let identity = try fileIdentity(candidate.url)
        items.append(
          makeItem(
            kind: .download,
            category: category,
            url: candidate.url,
            size: candidate.size,
            identity: identity,
            group: group
          )
        )
      } catch {
        issues.append(
          Self.scanIssue(at: candidate.url, error: error, home: home, configuredRoot: true)
        )
      }
    }

    items.sort { lhs, rhs in
      if lhs.category != rhs.category {
        return lhs.category.localizedStandardCompare(rhs.category) == .orderedAscending
      }
      if lhs.size != rhs.size { return lhs.size > rhs.size }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    return ScanResult(values: items, issues: uniqueIssues(issues), scannedCount: scanned)
  }

  func cleanup(
    items: [MaintenanceItem],
    cacheMode: CacheCleanupMode,
    allowedRoots: [URL],
    authorize: Bool,
    progress: CleanupReporter
  ) async -> CleanupResult {
    let ordered = items.enumerated().sorted { lhs, rhs in
      let lhsRank = lhs.element.kind == .application ? 0 : 1
      let rhsRank = rhs.element.kind == .application ? 0 : 1
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    var completedItems: [MaintenanceItem] = []
    var failures: [MaintenanceFailure] = []
    var handledBytes: UInt64 = 0

    for (offset, item) in ordered.enumerated() {
      if Task.isCancelled { break }
      await progress(
        CleanupProgress(
          completed: offset,
          total: ordered.count,
          item: item,
          state: .working,
          detail: ""
        ))
      do {
        try validate(item, allowedRoots: allowedRoots)
        if item.kind == .application, await applicationIsRunning(item.url) {
          throw MaintenanceServiceError.running
        }

        let permanentlyDelete =
          cacheMode == .delete
          && (item.kind == .cache || item.kind == .developer)
        if permanentlyDelete {
          try fileManager.removeItem(at: item.url)
        } else if authorize, item.kind == .application,
          item.url.standardizedFileURL.path.hasPrefix("/Applications/")
        {
          switch SystemPermission.moveToTrashWithAdministratorAuthorization(item.url) {
          case .success:
            break
          case .cancelled:
            await progress(
              CleanupProgress(
                completed: offset,
                total: ordered.count,
                item: item,
                state: .failed,
                detail: "Cancelled"
              ))
            return CleanupResult(
              completed: completedItems,
              failures: failures,
              reclaimedBytes: handledBytes,
              authorizationCancelled: true
            )
          case .failure(let message):
            throw MaintenanceServiceError.administratorAuthorizationFailed(message)
          }
        } else {
          try fileManager.trashItem(at: item.url, resultingItemURL: nil)
        }
        if item.kind == .application {
          SystemPermission.unregisterApplication(at: item.url)
        }
        completedItems.append(item)
        handledBytes += item.size
        await progress(
          CleanupProgress(
            completed: offset + 1,
            total: ordered.count,
            item: item,
            state: .completed,
            detail: permanentlyDelete ? "Deleted" : "Moved to Trash"
          ))
      } catch {
        let failure = classifyFailure(item: item, error: error)
        failures.append(failure)
        await progress(
          CleanupProgress(
            completed: offset + 1,
            total: ordered.count,
            item: item,
            state: .failed,
            detail: failure.detail
          ))
      }
    }
    return CleanupResult(
      completed: completedItems,
      failures: failures,
      reclaimedBytes: handledBytes,
      authorizationCancelled: false
    )
  }

  func releaseMemory() -> MemoryReleaseResult {
    guard fileManager.isExecutableFile(atPath: "/usr/bin/purge") else {
      return .failure("The purge utility is unavailable on this version of macOS.")
    }
    switch SystemPermission.purgeFileCacheWithAdministratorAuthorization() {
    case .success: return .success
    case .cancelled: return .cancelled
    case .failure(let message): return .failure(message)
    }
  }

  private func residueItems(bundleID: String, parentID: String) async throws
    -> (items: [MaintenanceItem], issues: [ScanIssue])
  {
    guard !bundleID.isEmpty else { return ([], []) }
    let library = home.appendingPathComponent("Library", isDirectory: true)
    let candidates: [(URL, String)] = [
      (library.appendingPathComponent("Caches/\(bundleID)"), "Cache"),
      (library.appendingPathComponent("Preferences/\(bundleID).plist"), "Preferences"),
      (
        library.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
        "Saved State"
      ),
      (library.appendingPathComponent("Application Support/\(bundleID)"), "Application Support"),
      (library.appendingPathComponent("Containers/\(bundleID)"), "Container"),
      (library.appendingPathComponent("HTTPStorages/\(bundleID)"), "Web Data"),
      (library.appendingPathComponent("WebKit/\(bundleID)"), "Web Data"),
    ]
    var items: [MaintenanceItem] = []
    var issues: [ScanIssue] = []
    for (url, category) in candidates {
      guard fileManager.fileExists(atPath: url.path) else { continue }
      do {
        let (size, _) = try await pathSize(url)
        let identity = try fileIdentity(url)
        items.append(
          makeItem(
            kind: .residue,
            category: category,
            url: url,
            size: size,
            identity: identity,
            group: bundleID,
            parentID: parentID
          )
        )
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        issues.append(Self.scanIssue(at: url, error: error, home: home))
      }
    }
    return (items, issues)
  }

  private func applicationMetadata(_ url: URL) -> (bundleID: String, name: String, version: String)
  {
    let bundle = Bundle(url: url)
    let identifier = bundle?.bundleIdentifier ?? ""
    let name =
      bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? url.deletingPathExtension().lastPathComponent
    let version =
      bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    return (identifier, name, version)
  }

  private func makeItem(
    kind: MaintenanceItemKind,
    category: String,
    name: String? = nil,
    url: URL,
    size: UInt64,
    identity: FileIdentity,
    group: String = "",
    parentID: String? = nil
  ) -> MaintenanceItem {
    MaintenanceItem(
      kind: kind,
      category: category,
      name: name,
      url: url.standardizedFileURL,
      size: size,
      modified: Date(timeIntervalSince1970: identity.modified),
      identity: identity,
      group: group,
      parentID: parentID
    )
  }

  private func pathSize(_ url: URL) async throws -> (UInt64, Int) {
    let values = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      return (UInt64(max(0, values.fileSize ?? 0)), 1)
    }
    var total: UInt64 = 0
    var count = 0
    let enumerator = fileManager.enumerator(
      at: url,
      includingPropertiesForKeys: [
        .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]
    )
    var visited = 0
    while let child = enumerator?.nextObject() as? URL {
      visited += 1
      if visited.isMultiple(of: 256) {
        try Task.checkCancellation()
        await Task.yield()
      }
      guard let childValues = try? child.resourceValues(forKeys: [
          .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]) else { continue }
      if childValues.isSymbolicLink == true {
        enumerator?.skipDescendants()
        continue
      }
      guard childValues.isRegularFile == true else { continue }
      total += UInt64(max(0, childValues.fileAllocatedSize ?? childValues.fileSize ?? 0))
      count += 1
    }
    return (total, max(1, count))
  }

  private func fileIdentity(_ url: URL) throws -> FileIdentity {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    return FileIdentity(
      device: (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
      inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
      size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
      modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    )
  }

  private func hashFile(_ url: URL) async throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
      await Task.yield()
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func safeScanRoots(_ roots: [URL]) -> [URL] {
    roots.map(\.standardizedFileURL).filter { root in
      root.path != "/"
        && root.path != "/System"
        && !root.path.hasPrefix("/System/")
        && root.path != "/Library"
        && !root.path.hasPrefix("/Library/")
    }
  }

  private static func scanIssue(
    at url: URL,
    error: Error,
    home: URL,
    configuredRoot: Bool = false
  ) -> ScanIssue {
    let errors = errorChain(error as NSError)
    let isUnavailable = errors.contains { error in
      (error.domain == NSCocoaErrorDomain
        && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
        || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
    let isPermissionDenied = errors.contains { error in
      (error.domain == NSCocoaErrorDomain
        && (error.code == NSFileReadNoPermissionError
          || error.code == NSFileWriteNoPermissionError))
        || (error.domain == NSPOSIXErrorDomain
          && (error.code == Int(EACCES) || error.code == Int(EPERM)))
    }

    let kind: ScanIssueKind
    if isUnavailable {
      kind = .unavailable
    } else if isPermissionDenied
      && filesAndFoldersRoots(home: home).contains(where: { contains(url, in: $0) })
    {
      kind = .filesAndFolders
    } else if isPermissionDenied
      && contains(url, in: home.appendingPathComponent("Library", isDirectory: true))
    {
      kind = .fullDiskAccess
    } else if isPermissionDenied && configuredRoot {
      kind = .folderAccess
    } else {
      kind = .other
    }

    return ScanIssue(
      url: url.standardizedFileURL,
      kind: kind,
      detail: error.localizedDescription
    )
  }

  private static func filesAndFoldersRoots(home: URL) -> [URL] {
    ["Desktop", "Documents", "Downloads"].map {
      home.appendingPathComponent($0, isDirectory: true).standardizedFileURL
    }
  }

  private static func contains(_ url: URL, in root: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return path == rootPath || path.hasPrefix(rootPath + "/")
  }

  private static func errorChain(_ error: NSError) -> [NSError] {
    var errors: [NSError] = []
    var nextError: NSError? = error
    while let current = nextError {
      errors.append(current)
      nextError = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return errors
  }

  private func uniqueIssues(_ issues: [ScanIssue]) -> [ScanIssue] {
    var ids = Set<ScanIssue.ID>()
    return issues.filter { ids.insert($0.id).inserted }
  }

  private func validate(_ item: MaintenanceItem, allowedRoots: [URL]) throws {
    guard fileManager.fileExists(atPath: item.url.path) else {
      throw MaintenanceServiceError.notFound
    }
    let path = item.url.standardizedFileURL.path
    let roots = allowedRoots.map(\.standardizedFileURL.path)
    let isAllowed = roots.contains { root in
      path != root && path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
    guard isAllowed, !path.hasPrefix("/System/") else {
      throw MaintenanceServiceError.outsideScope
    }
    guard try fileIdentity(item.url) == item.identity else {
      throw MaintenanceServiceError.changed
    }
  }

  private func applicationIsRunning(_ url: URL) async -> Bool {
    await MainActor.run {
      NSWorkspace.shared.runningApplications.contains { application in
        guard let bundleURL = application.bundleURL?.standardizedFileURL else { return false }
        return bundleURL == url.standardizedFileURL
          || bundleURL.path.hasPrefix(url.standardizedFileURL.path + "/")
      }
    }
  }

  private func classifyFailure(item: MaintenanceItem, error: Error) -> MaintenanceFailure {
    if let serviceError = error as? MaintenanceServiceError {
      return MaintenanceFailure(
        item: item,
        kind: serviceError.failureKind,
        detail: serviceError.localizedDescription
      )
    }
    let cocoaError = error as NSError
    let permissionDenied =
      cocoaError.code == NSFileWriteNoPermissionError
      || cocoaError.code == Int(EACCES)
      || cocoaError.code == Int(EPERM)
      || cocoaError.localizedDescription.localizedCaseInsensitiveContains("permission")
      || cocoaError.localizedDescription.localizedCaseInsensitiveContains("not permitted")
    let kind: MaintenanceFailureKind
    if permissionDenied,
      item.url.standardizedFileURL.path.hasPrefix(home.appendingPathComponent("Library").path + "/")
    {
      kind = .fullDiskAccess
    } else if permissionDenied,
      Self.filesAndFoldersRoots(home: home).contains(where: { Self.contains(item.url, in: $0) })
    {
      kind = .filesAndFolders
    } else if permissionDenied, item.kind == .application,
      item.url.path.hasPrefix("/Applications/")
    {
      kind = .administratorRequired
    } else if permissionDenied {
      kind = .permission
    } else {
      kind = .operationFailed
    }
    return MaintenanceFailure(item: item, kind: kind, detail: error.localizedDescription)
  }
}

private struct DownloadCandidate: Sendable {
  let url: URL
  let size: UInt64
  let modified: Date
}

private enum MaintenanceServiceError: LocalizedError {
  case notFound
  case changed
  case outsideScope
  case running
  case administratorAuthorizationFailed(String)

  var errorDescription: String? {
    switch self {
    case .notFound: "The item no longer exists."
    case .changed: "The item changed after it was scanned. Scan again before removing it."
    case .outsideScope: "The item is outside the allowed cleanup folders."
    case .running: "Quit the application before uninstalling it."
    case .administratorAuthorizationFailed(let message): message
    }
  }

  var failureKind: MaintenanceFailureKind {
    switch self {
    case .notFound: .notFound
    case .changed: .changed
    case .outsideScope: .outsideScope
    case .running: .running
    case .administratorAuthorizationFailed: .administratorRequired
    }
  }
}
