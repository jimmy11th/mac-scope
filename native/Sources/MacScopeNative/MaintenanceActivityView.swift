import SwiftUI

struct MaintenanceActivityInlineView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  let tool: MaintenanceTool

  private var activity: MaintenanceActivity? {
    guard store.activity?.tool == tool else { return nil }
    return store.activity
  }

  private var issueCount: Int {
    guard let activity else { return 0 }
    return max(
      activity.failures.count,
      activity.entries.filter { $0.state == .failed }.count
    )
  }

  private var showsEntries: Bool {
    guard let activity else { return false }
    return !activity.entries.isEmpty
      && (activity.operation == .cleanup || issueCount > 0)
  }

  var body: some View {
    if let activity {
      VStack(alignment: .leading, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 10) {
            activityIcon(for: activity)
              .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
              Text(activity.title)
                .font(.subheadline.weight(.semibold))
              Text(statusText(for: activity))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
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
              }
              .buttonStyle(.plain)
              .help("Dismiss")
            }
          }

          if store.isBusy {
            if let progress = activity.progress {
              ProgressView(value: progress)
            }
          }

          if shouldShowCurrentPath(for: activity) {
            Text(activity.currentPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }

          if store.needsFullDiskAccess {
            Button(action: SystemPermission.openFullDiskAccessSettings) {
              Label("Open Full Disk Access", systemImage: "lock.open")
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)

        if showsEntries {
          Divider()
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(activity.entries) { entry in
                activityRow(entry)
                if entry.id != activity.entries.last?.id {
                  Divider()
                    .padding(.leading, 42)
                }
              }
            }
          }
          .frame(maxHeight: min(190, CGFloat(activity.entries.count) * 48))
          .compactNativeScrollers()
        }

        if activity.reclaimedBytes > 0 {
          Divider()
          Text(
            AppLocalization.string(
              "Handled %@",
              language: settings.language,
              arguments: [DisplayFormat.bytes(activity.reclaimedBytes)]
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
          .frame(height: 32)
        }
      }
      .background(Color(nsColor: .controlBackgroundColor))
      .transition(.opacity)
    }
  }

  private func activityRow(_ entry: ActivityEntry) -> some View {
    HStack(spacing: 10) {
      entryStateView(entry.state)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(entry.name))
          .lineLimit(1)
        Text(entry.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if !entry.detail.isEmpty, entry.detail != entry.path {
          Text(entry.detail)
            .font(.caption)
            .foregroundStyle(entry.state == .failed ? Color.red : Color.secondary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private func activityIcon(for activity: MaintenanceActivity) -> some View {
    switch activity.phase {
    case .scanning, .working:
      ProgressView()
        .controlSize(.small)
    case .completed:
      Image(systemName: issueCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
        .foregroundStyle(issueCount > 0 ? Color.orange : Color.green)
    case .cancelled:
      Image(systemName: "xmark.circle")
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

  private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.string(key, language: settings.language, arguments: arguments)
  }
}
