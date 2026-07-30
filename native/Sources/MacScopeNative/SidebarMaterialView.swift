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
    effectView.state = .active
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
    effectView.alphaValue = isEnabled ? 1 - (normalizedTransparency * 0.45) : 0
    let tintOpacity = isEnabled ? pow(1 - normalizedTransparency, 1.35) : 1
    tintView.layer?.backgroundColor = NSColor.windowBackgroundColor
      .withAlphaComponent(tintOpacity).cgColor
  }
}
