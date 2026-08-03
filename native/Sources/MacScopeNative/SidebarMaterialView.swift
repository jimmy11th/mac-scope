import AppKit
import SwiftUI

struct SidebarItemIcon: View {
  let systemImage: String
  let color: Color

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(color.gradient)
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
      Image(systemName: systemImage)
        .symbolRenderingMode(.monochrome)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
    }
    .frame(width: 20, height: 20)
    .shadow(color: .black.opacity(0.14), radius: 1, y: 0.5)
    .accessibilityHidden(true)
  }
}

struct SidebarMaterialView: NSViewRepresentable {
  let isEnabled: Bool
  let transparency: Double

  func makeNSView(context: Context) -> NativeSidebarMaterialView {
    let view = NativeSidebarMaterialView()
    view.update(isEnabled: isEnabled, transparency: transparency)
    return view
  }

  func updateNSView(_ view: NativeSidebarMaterialView, context: Context) {
    view.update(isEnabled: isEnabled, transparency: transparency)
  }
}

final class NativeSidebarMaterialView: NSVisualEffectView {
  private let tintView = NSView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    material = .sidebar
    blendingMode = .behindWindow
    state = .followsWindowActiveState

    tintView.wantsLayer = true
    tintView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(tintView)
    NSLayoutConstraint.activate([
      tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tintView.topAnchor.constraint(equalTo: topAnchor),
      tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateTintColor()
  }

  func update(isEnabled: Bool, transparency: Double) {
    let normalizedTransparency = min(1, max(0, transparency))
    tintView.alphaValue = isEnabled ? 1 - normalizedTransparency : 1
    updateTintColor()
  }

  private func updateTintColor() {
    tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
  }
}
