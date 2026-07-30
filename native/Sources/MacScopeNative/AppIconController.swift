import AppKit

@MainActor
enum AppIconController {
  private static var images: [AppIconStyle: NSImage] = [:]

  static func image(for style: AppIconStyle) -> NSImage? {
    if let image = images[style] {
      return image
    }
    guard
      let url = Bundle.main.url(forResource: style.resourceName, withExtension: "icns"),
      let image = NSImage(contentsOf: url)
    else {
      return nil
    }
    images[style] = image
    return image
  }

  static func apply(_ style: AppIconStyle) {
    guard let image = image(for: style) else { return }
    NSApplication.shared.applicationIconImage = image
  }
}
