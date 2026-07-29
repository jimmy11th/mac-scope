import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private var terminalController: TerminalHostViewController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let controller = TerminalHostViewController()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullScreen],
      backing: .buffered,
      defer: false
    )
    window.title = "MacScope"
    window.contentViewController = controller
    window.minSize = NSSize(width: 820, height: 560)
    window.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
    window.collectionBehavior = [.fullScreenPrimary]
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.setFrameAutosaveName("MacScopeMainWindow")
    window.center()

    terminalController = controller
    self.window = window
    NSApplication.shared.mainMenu = makeMainMenu()
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  func applicationWillTerminate(_ notification: Notification) {
    terminalController?.terminateProcess()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    true
  }

  func windowWillClose(_ notification: Notification) {
    terminalController?.terminateProcess()
  }

  private func makeMainMenu() -> NSMenu {
    let mainMenu = NSMenu(title: "Main Menu")
    let applicationItem = NSMenuItem()
    let editItem = NSMenuItem()
    let windowItem = NSMenuItem()

    mainMenu.addItem(applicationItem)
    mainMenu.addItem(editItem)
    mainMenu.addItem(windowItem)

    applicationItem.submenu = makeApplicationMenu()
    editItem.submenu = makeEditMenu()
    windowItem.submenu = makeWindowMenu()
    NSApplication.shared.windowsMenu = windowItem.submenu
    return mainMenu
  }

  private func makeApplicationMenu() -> NSMenu {
    let menu = NSMenu(title: "MacScope")
    menu.addItem(
      withTitle: "About MacScope",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Hide MacScope",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = menu.addItem(
      withTitle: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit MacScope",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    return menu
  }

  private func makeEditMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    menu.addItem(
      withTitle: "Copy",
      action: #selector(NSText.copy(_:)),
      keyEquivalent: "c"
    )
    menu.addItem(
      withTitle: "Paste",
      action: #selector(NSText.paste(_:)),
      keyEquivalent: "v"
    )
    menu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    return menu
  }

  private func makeWindowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )
    return menu
  }
}
