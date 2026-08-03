import SwiftUI

struct MaintenanceActivityInlineView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  let tool: MaintenanceTool

  @State private var showsResults = false

  private var activity: MaintenanceActivity? {
    guard store.activity?.tool == tool else { return nil }
    return store.activity
  }

  private var issueCount: Int {
    guard let activity else { return 0 }
    return [
      activity.failures.count,
      activity.scanIssues.count,
      activity.entries.filter { $0.state == .failed }.count,
    ].max() ?? 0
  }

  private var canShowResults: Bool {
    guard let activity, !activity.entries.isEmpty else { return false }
    return switch activity.phase {
    case .completed, .cancelled:
      true
    case .scanning, .working:
      false
    }
  }

  var body: some View {
    if let activity {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 12) {
          activityIcon(for: activity)
            .frame(width: 24, height: 24)

          VStack(alignment: .leading, spacing: 2) {
            Text(activity.title)
              .font(.subheadline.weight(.semibold))
            Text(statusText(for: activity))
              .font(.caption)
              .foregroundStyle(.secondary)

            if shouldShowCurrentPath(for: activity) {
              Text(activity.currentPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }

          Spacer(minLength: 16)

          if activity.reclaimedBytes > 0 {
            Text(
              AppLocalization.string(
                "Handled %@",
                language: settings.language,
                arguments: [DisplayFormat.bytes(activity.reclaimedBytes)]
              )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
          }

          if canShowResults {
            Button {
              showsResults = true
            } label: {
              Label("View Results", systemImage: "list.bullet.rectangle")
            }
          }

          if store.isBusy {
            Button {
              store.cancelCurrentOperation()
            } label: {
              Label("Cancel", systemImage: "xmark")
            }
          } else {
            Button {
              store.dismissActivity()
            } label: {
              Image(systemName: "xmark")
                .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        if store.isBusy, let progress = activity.progress {
          ProgressView(value: progress)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
      }
      .background(.bar)
      .transition(.opacity)
      .sheet(isPresented: $showsResults) {
        MaintenanceActivityResultsView(
          activity: activity,
          tool: tool,
          statusText: statusText(for: activity),
          issueCount: issueCount
        )
      }
    }
  }

  @ViewBuilder
  private func activityIcon(for activity: MaintenanceActivity) -> some View {
    switch activity.phase {
    case .scanning, .working:
      ProgressView()
        .controlSize(.small)
    case .completed:
      Image(systemName: issueCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(issueCount > 0 ? Color.orange : Color.green)
    case .cancelled:
      Image(systemName: "xmark.circle")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  private func statusText(for activity: MaintenanceActivity) -> String {
    switch activity.phase {
    case .scanning:
      return activity.completed > 0
        ? localized("%lld files scanned", Int64(activity.completed))
        : localized("Scanning")
    case .working:
      return localized(
        "%lld of %lld completed",
        Int64(activity.completed),
        Int64(activity.total)
      )
    case .completed:
      return issueCount == 0
        ? localized("Completed")
        : localized("%lld items need attention", Int64(issueCount))
    case .cancelled:
      return localized("Cancelled")
    }
  }

  private func shouldShowCurrentPath(for activity: MaintenanceActivity) -> Bool {
    guard !activity.currentPath.isEmpty else { return false }
    switch activity.phase {
    case .scanning, .working:
      return true
    case .completed:
      switch activity.operation {
      case .scan, .memory:
        return true
      case .cleanup:
        return false
      }
    case .cancelled:
      return false
    }
  }

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}

private struct MaintenanceActivityResultsView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  let activity: MaintenanceActivity
  let tool: MaintenanceTool
  let statusText: String
  let issueCount: Int

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        resultIcon
          .frame(width: 32, height: 32)

        VStack(alignment: .leading, spacing: 3) {
          Text(activity.title)
            .font(.title3.weight(.semibold))
          Text(statusText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 18)

      Divider()
      summaryStrip
      Divider()

      List(activity.entries) { entry in
        resultRow(entry)
      }
      .listStyle(.inset)
      .compactNativeScrollers()

      Divider()
      HStack(spacing: 8) {
        recoveryActions
        Spacer()
        Button("Done") {
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(.bar)
    }
    .frame(width: 760, height: 520)
  }

  private var summaryStrip: some View {
    HStack(spacing: 0) {
      summaryItem(
        systemImage: "checkmark.circle",
        title: "Items Processed",
        value: String(activity.completed),
        color: .secondary
      )

      if activity.reclaimedBytes > 0 {
        Divider()
          .frame(height: 34)
        summaryItem(
          systemImage: "internaldrive",
          title: "Data Handled",
          value: DisplayFormat.bytes(activity.reclaimedBytes),
          color: .secondary
        )
      }

      if issueCount > 0 {
        Divider()
          .frame(height: 34)
        summaryItem(
          systemImage: "exclamationmark.triangle",
          title: "Needs Attention",
          value: String(issueCount),
          color: .orange
        )
      }
    }
    .padding(.horizontal, 20)
    .frame(height: 68)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private func summaryItem(
    systemImage: String,
    title: LocalizedStringKey,
    value: String,
    color: Color
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(color)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(value)
          .font(.headline)
          .monospacedDigit()
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func resultRow(_ entry: ActivityEntry) -> some View {
    HStack(alignment: .top, spacing: 12) {
      entryStateView(entry.state)
        .frame(width: 20, height: 20)

      VStack(alignment: .leading, spacing: 3) {
        Text(LocalizedStringKey(entry.name))
          .font(.body.weight(.medium))
          .lineLimit(1)

        if !entry.path.isEmpty {
          Text(entry.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(entry.path)
        }

        if !entry.detail.isEmpty, entry.detail != entry.path {
          Text(entry.detail)
            .font(.caption)
            .foregroundStyle(entry.state == .failed ? Color.red : Color.secondary)
            .lineLimit(3)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
  }

  @ViewBuilder
  private var resultIcon: some View {
    switch activity.phase {
    case .scanning, .working:
      ProgressView()
        .controlSize(.regular)
    case .completed:
      Image(systemName: issueCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(issueCount > 0 ? Color.orange : Color.green)
    case .cancelled:
      Image(systemName: "xmark.circle")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var recoveryActions: some View {
    if hasPermissionRecoveryActions {
      Menu {
        if store.needsFilesAndFoldersAccess {
          Button(action: SystemPermission.openFilesAndFoldersSettings) {
            Label("Open Files & Folders Settings", systemImage: "folder.badge.gearshape")
          }
        }

        if store.needsFullDiskAccess {
          Button(action: SystemPermission.openFullDiskAccessSettings) {
            Label("Open Full Disk Access", systemImage: "lock.open")
          }
        }

        if store.needsScanFolderAccess {
          Button {
            AppWindowActions.openSettings(tab: "cleanup")
          } label: {
            Label("Manage Scan Folders", systemImage: "folder.badge.gearshape")
          }
        }

        if canRetryScan {
          Divider()
          Button(action: retryScan) {
            Label("Scan Again", systemImage: "arrow.clockwise")
          }
        }
      } label: {
        Label("Resolve Issues", systemImage: "wrench.and.screwdriver")
      }
    } else if canRetryScan {
      Button(action: retryScan) {
        Label("Scan Again", systemImage: "arrow.clockwise")
      }
    }
  }

  @ViewBuilder
  private func entryStateView(_ state: ActivityEntryState) -> some View {
    switch state {
    case .pending:
      Image(systemName: "circle")
        .foregroundStyle(.tertiary)
    case .working:
      ProgressView()
        .controlSize(.small)
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    }
  }

  private var hasPermissionRecoveryActions: Bool {
    store.needsFilesAndFoldersAccess
      || store.needsFullDiskAccess
      || store.needsScanFolderAccess
  }

  private var canRetryScan: Bool {
    activity.operation == .scan
      && activity.phase == .completed
      && !activity.scanIssues.isEmpty
  }

  private func retryScan() {
    dismiss()
    store.retryScan(tool: tool, settings: settings)
  }
}
