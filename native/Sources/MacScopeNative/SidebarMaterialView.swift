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

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    effectView.material = .sidebar
    effectView.blendingMode = .behindWindow
    effectView.state = .followsWindowActiveState
    effectView.autoresizingMask = [.width, .height]
    tintView.wantsLayer = true
    tintView.autoresizingMask = [.width, .height]
    addSubview(effectView)
    addSubview(tintView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    effectView.frame = bounds
    tintView.frame = bounds
  }

  func update(isEnabled: Bool, transparency: Double) {
    effectView.isHidden = !isEnabled
    let normalizedTransparency = min(1, max(0, transparency))
    let tintOpacity = isEnabled ? 1 - normalizedTransparency : 1
    tintView.layer?.backgroundColor = NSColor.windowBackgroundColor
      .withAlphaComponent(tintOpacity).cgColor
  }
}
