import AppKit
import SwiftUI

struct MainWindowConfigurationView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    configureWhenAttached(view)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    configureWhenAttached(view)
  }

  private func configureWhenAttached(_ view: NSView) {
    DispatchQueue.main.async {
      guard let window = view.window else { return }

      window.styleMask.formUnion([
        .titled,
        .closable,
        .miniaturizable,
        .resizable,
      ])
      window.contentMinSize = NSSize(width: 1_020, height: 620)
      window.contentResizeIncrements = NSSize(width: 1, height: 1)
      window.collectionBehavior.insert(.fullScreenPrimary)

      if let zoomButton = window.standardWindowButton(.zoomButton) {
        zoomButton.isEnabled = true
        zoomButton.isHidden = false
      }

      _ = window.setFrameAutosaveName("MacScope.MainWindow")
    }
  }
}
