import SwiftUI

struct SystemToolHeader<Actions: View>: View {
  let title: LocalizedStringKey
  let subtitle: LocalizedStringKey
  @ViewBuilder let actions: Actions

  init(
    _ title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.subtitle = subtitle
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .center, spacing: 20) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title2.weight(.semibold))
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 20)
      HStack(spacing: 8) {
        actions
      }
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 16)
  }
}

struct SystemToolEmptyView<Action: View>: View {
  let systemImage: String
  let title: LocalizedStringKey
  let message: LocalizedStringKey
  @ViewBuilder let action: Action

  init(
    systemImage: String,
    title: LocalizedStringKey,
    message: LocalizedStringKey,
    @ViewBuilder action: () -> Action
  ) {
    self.systemImage = systemImage
    self.title = title
    self.message = message
    self.action = action()
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 38, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.headline)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      action
        .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}

struct SelectionCheckbox: View {
  @Binding var isSelected: Bool
  var isEnabled = true

  var body: some View {
    Toggle("", isOn: $isSelected)
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(!isEnabled)
      .frame(maxWidth: .infinity, alignment: .center)
  }
}

struct SystemToolStatusBar<Actions: View>: View {
  let summary: String
  @ViewBuilder let actions: Actions

  init(summary: String, @ViewBuilder actions: () -> Actions) {
    self.summary = summary
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: 12) {
      Text(summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Spacer()
      actions
    }
    .padding(.horizontal, 14)
    .frame(height: 46)
    .background(Color(nsColor: .controlBackgroundColor))
  }
}

