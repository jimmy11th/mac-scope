import AppKit
import SwiftUI

struct CompactScrollerConfigurationView: NSViewRepresentable {
  let clearsBackground: Bool

  func makeNSView(context: Context) -> NSView {
    ScrollViewLocator(clearsBackground: clearsBackground)
  }

  func updateNSView(_ view: NSView, context: Context) {
    (view as? ScrollViewLocator)?.configureWhenReady()
  }
}

private final class ScrollViewLocator: NSView {
  private let clearsBackground: Bool
  private weak var configuredScrollView: NSScrollView?
  private var configurationScheduled = false
  private var configurationAttempts = 0

  init(clearsBackground: Bool) {
    self.clearsBackground = clearsBackground
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWhenReady()
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    configureWhenReady()
  }

  func configureWhenReady() {
    guard configuredScrollView == nil, !configurationScheduled else { return }
    configurationScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.configurationScheduled = false
      self.configurationAttempts += 1
      if !self.configureNearestScrollView(), self.configurationAttempts < 4 {
        self.configureWhenReady()
      }
    }
  }

  private func configureNearestScrollView() -> Bool {
    guard window != nil, !bounds.isEmpty else { return false }
    let markerFrame = convert(bounds, to: nil)
    let scrollView: NSScrollView?
    if let enclosingScrollView {
      scrollView = enclosingScrollView
    } else {
      scrollView = nearestOverlappingScrollView(markerFrame: markerFrame)
    }
    guard let scrollView else { return false }

    configuredScrollView = scrollView
    scrollView.scrollerStyle = .overlay
    scrollView.autohidesScrollers = true
    scrollView.verticalScroller?.controlSize = .small
    scrollView.horizontalScroller?.controlSize = .small
    if clearsBackground {
      scrollView.drawsBackground = false
      scrollView.backgroundColor = .clear
      scrollView.contentView.drawsBackground = false
      scrollView.contentView.backgroundColor = .clear
      if let tableView = scrollView.documentView as? NSTableView {
        tableView.backgroundColor = .clear
      }
    }
    scrollView.tile()
    return true
  }

  private func nearestOverlappingScrollView(markerFrame: NSRect) -> NSScrollView? {
    var ancestor = superview
    while let current = ancestor {
      let matching = scrollViews(in: current).filter {
        intersectionArea(of: $0, with: markerFrame) > 0
      }
      if let bestMatch = matching.max(by: {
        intersectionArea(of: $0, with: markerFrame)
          < intersectionArea(of: $1, with: markerFrame)
      }) {
        return bestMatch
      }
      ancestor = current.superview
    }
    return nil
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
  func compactNativeScrollers(clearsBackground: Bool = false) -> some View {
    background {
      CompactScrollerConfigurationView(clearsBackground: clearsBackground)
        .allowsHitTesting(false)
    }
  }
}
