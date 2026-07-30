import AppKit
import SwiftUI

struct CompactScrollerConfigurationView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    ScrollViewLocator()
  }

  func updateNSView(_ view: NSView, context: Context) {
    (view as? ScrollViewLocator)?.configureWhenReady()
  }
}

private final class ScrollViewLocator: NSView {
  private weak var configuredScrollView: NSScrollView?
  private var configurationScheduled = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWhenReady()
  }

  override func layout() {
    super.layout()
    configureWhenReady()
  }

  func configureWhenReady() {
    guard configuredScrollView == nil, !configurationScheduled else { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.configurationScheduled = false
      self.configureNearestScrollView()
    }
  }

  private func configureNearestScrollView() {
    guard let contentView = window?.contentView, !bounds.isEmpty else { return }
    let markerFrame = convert(bounds, to: nil)
    let candidates = scrollViews(in: contentView)
    let bestMatch = candidates.max { lhs, rhs in
      intersectionArea(of: lhs, with: markerFrame) < intersectionArea(of: rhs, with: markerFrame)
    }
    guard let scrollView = bestMatch,
      intersectionArea(of: scrollView, with: markerFrame) > 0
    else {
      return
    }

    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller?.controlSize = .small
    scrollView.horizontalScroller?.controlSize = .small
    scrollView.tile()
    configuredScrollView = scrollView
  }

  private func scrollViews(in root: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    var pending = [root]
    while let view = pending.popLast() {
      if let scrollView = view as? NSScrollView {
        result.append(scrollView)
      }
      pending.append(contentsOf: view.subviews)
    }
    return result
  }

  private func intersectionArea(of scrollView: NSScrollView, with markerFrame: NSRect) -> CGFloat {
    let frame = scrollView.convert(scrollView.bounds, to: nil)
    let intersection = frame.intersection(markerFrame)
    return intersection.isNull ? 0 : intersection.width * intersection.height
  }
}

extension View {
  func compactNativeScrollers() -> some View {
    background {
      CompactScrollerConfigurationView()
        .allowsHitTesting(false)
    }
  }
}
