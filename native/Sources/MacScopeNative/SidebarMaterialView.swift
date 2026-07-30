import AppKit
import SwiftUI

struct SidebarMaterialView: NSViewRepresentable {
  let isEnabled: Bool
  let transparency: Double

  func makeNSView(context: Context) -> AdjustableSidebarMaterialView {
    let view = AdjustableSidebarMaterialView()
    view.update(isEnabled: isEnabled, transparency: transparency)
    return view
  }

  func updateNSView(_ view: AdjustableSidebarMaterialView, context: Context) {
    view.update(isEnabled: isEnabled, transparency: transparency)
  }
}

final class AdjustableSidebarMaterialView: NSView {
  private let effectView = NSVisualEffectView()
  private let tintView = NSView()
  private var isEnabled = true
  private var transparency = 0.7

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    effectView.material = .sidebar
    effectView.blendingMode = .behindWindow
    effectView.state = .active
    effectView.translatesAutoresizingMaskIntoConstraints = false
    tintView.wantsLayer = true
    tintView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(effectView)
    addSubview(tintView)
    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    updateAppearance()
  }

  func update(isEnabled: Bool, transparency: Double) {
    self.isEnabled = isEnabled
    self.transparency = min(1, max(0, transparency))
    updateAppearance()
  }

  private func updateAppearance() {
    effectView.isHidden = !isEnabled
    let tintOpacity = isEnabled ? 1 - transparency : 1
    tintView.layer?.backgroundColor = NSColor.windowBackgroundColor
      .withAlphaComponent(tintOpacity).cgColor
  }
}
