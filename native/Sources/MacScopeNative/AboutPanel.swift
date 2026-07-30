import AppKit

@MainActor
enum AboutPanel {
  static func show(language: AppLanguage) {
    let credits = NSMutableAttributedString(
      string: AppLocalization.string(
        "MacScope is an open source macOS system utility.",
        language: language
      ) + "\n"
    )
    let link = NSAttributedString(
      string: "github.com/shenmuoso/mac-scope",
      attributes: [
        .link: AppLinks.github,
        .foregroundColor: NSColor.linkColor,
      ]
    )
    credits.append(link)

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    credits.addAttribute(
      .paragraphStyle,
      value: paragraphStyle,
      range: NSRange(location: 0, length: credits.length)
    )

    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
  }
}
