import AppKit
import SwiftUI

private enum GitHubAsset {
  static let mark: NSImage = {
    let image = Bundle.main.url(forResource: "GitHubMark", withExtension: "svg")
      .flatMap(NSImage.init(contentsOf:))
      ?? NSImage(
        systemSymbolName: "chevron.left.forwardslash.chevron.right",
        accessibilityDescription: "GitHub"
      )
      ?? NSImage(size: NSSize(width: 14, height: 14))
    image.isTemplate = true
    return image
  }()
}

struct GitHubLinkLabel: View {
  let title: LocalizedStringKey
  var iconSize: CGFloat = 14

  var body: some View {
    Label {
      Text(title)
    } icon: {
      Image(nsImage: GitHubAsset.mark)
        .resizable()
        .renderingMode(.template)
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
    }
  }
}
