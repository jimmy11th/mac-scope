import SwiftUI

struct MaintenanceActivityView: View {
  @EnvironmentObject private var store: MaintenanceStore
  @EnvironmentObject private var settings: AppSettings

  private var activity: MaintenanceActivity? { store.activity }

  private var issueCount: Int {
    guard let activity else { return 0 }
    return max(
      activity.failures.count,
      activity.entries.filter { $0.state == .failed }.count
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
          activityIcon
          VStack(alignment: .leading, spacing: 2) {
            Text(activity?.title ?? "System Tool")
              .font(.headline)
            Text(statusText)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Spacer()
        }

        if let progress = activity?.progress, store.isBusy {
          ProgressView(value: progress)
        } else if activity?.phase == .scanning {
          ProgressView()
            .controlSize(.small)
        }

        if let currentPath = activity?.currentPath, !currentPath.isEmpty {
          Text(currentPath)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(20)

      Divider()

      if let entries = activity?.entries, !entries.isEmpty {
        List(entries) { entry in
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
          }
          .padding(.vertical, 3)
        }
      } else {
        Spacer()
        Image(systemName: store.isBusy ? "gearshape.2" : "checkmark.circle")
          .font(.system(size: 34, weight: .light))
          .foregroundStyle(.secondary)
        Spacer()
      }

      Divider()
      HStack {
        if let activity, activity.reclaimedBytes > 0 {
          Text(
            AppLocalization.string(
              "Handled %@",
              language: settings.language,
              arguments: [DisplayFormat.bytes(activity.reclaimedBytes)]
            )
          )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if store.needsFullDiskAccess {
          Button("Open Full Disk Access", action: SystemPermission.openFullDiskAccessSettings)
        }
        if store.canRetryWithAdministrator {
          Button("Authorize and Retry") {
            store.retryWithAdministratorAuthorization()
          }
        }
        if store.isBusy {
          Button("Cancel", role: .cancel) {
            store.cancelCurrentOperation()
          }
        } else {
          Button("Done") {
            store.dismissActivity()
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .padding(12)
    }
    .frame(width: 680, height: 480)
    .interactiveDismissDisabled(store.isBusy)
  }

  @ViewBuilder
  private var activityIcon: some View {
    switch activity?.phase {
    case .scanning, .working:
      ProgressView()
        .controlSize(.small)
        .frame(width: 22, height: 22)
    case .completed:
      Image(systemName: issueCount > 0 ? "exclamationmark.circle" : "checkmark.circle.fill")
        .foregroundStyle(issueCount > 0 ? Color.orange : Color.green)
        .font(.title2)
    case .cancelled:
      Image(systemName: "xmark.circle")
        .foregroundStyle(.secondary)
        .font(.title2)
    case .none:
      Image(systemName: "gearshape")
        .font(.title2)
    }
  }

  private var statusText: String {
    guard let activity else { return "" }
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
