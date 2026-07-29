import AppKit
import MacScopeShellCore
@preconcurrency import SwiftTerm

@MainActor
final class TerminalHostViewController: NSViewController,
  @preconcurrency LocalProcessTerminalViewDelegate
{
  private var terminalView: LocalProcessTerminalView?
  private var statusView: NSView?
  private var processStarted = false
  private var isTerminating = false

  override func loadView() {
    let rootView = NSView()
    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1).cgColor
    view = rootView
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    guard !processStarted else {
      return
    }
    startProcess()
  }

  func terminateProcess() {
    guard !isTerminating else {
      return
    }
    isTerminating = true
    terminalView?.terminate()
  }

  func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

  func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
    view.window?.title = "MacScope"
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func processTerminated(source: TerminalView, exitCode: Int32?) {
    Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      processStarted = false
      if isTerminating {
        return
      }
      let termination = ProcessTermination(waitStatus: exitCode)
      if termination.succeeded {
        NSApplication.shared.terminate(nil)
        return
      }
      showStatus(
        message: "MacScope stopped",
        detail: termination.displayDescription,
        allowsRestart: true
      )
    }
  }

  private func startProcess() {
    isTerminating = false
    statusView?.removeFromSuperview()
    statusView = nil
    terminalView?.removeFromSuperview()

    do {
      let configuration = try LaunchConfiguration.resolve()
      let terminal = makeTerminalView()
      view.addSubview(terminal)
      NSLayoutConstraint.activate([
        terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        terminal.topAnchor.constraint(equalTo: view.topAnchor),
        terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      ])
      view.layoutSubtreeIfNeeded()
      terminalView = terminal
      processStarted = true
      terminal.startProcess(
        executable: configuration.executableURL.path,
        args: configuration.arguments,
        environment: configuration.environment,
        execName: "macscope",
        currentDirectory: configuration.currentDirectoryURL.path
      )
      DispatchQueue.main.async { [weak self, weak terminal] in
        guard let self, let terminal else {
          return
        }
        self.view.window?.makeFirstResponder(terminal)
      }
    } catch {
      showStatus(
        message: "MacScope could not start",
        detail: error.localizedDescription,
        allowsRestart: true
      )
    }
  }

  private func makeTerminalView() -> LocalProcessTerminalView {
    let terminal = LocalProcessTerminalView(frame: .zero)
    terminal.translatesAutoresizingMaskIntoConstraints = false
    terminal.processDelegate = self
    terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    terminal.nativeForegroundColor = NSColor(calibratedWhite: 0.9, alpha: 1)
    terminal.nativeBackgroundColor = NSColor(calibratedWhite: 0.055, alpha: 1)
    terminal.caretColor = NSColor.systemTeal
    terminal.getTerminal().setCursorStyle(.steadyBlock)
    do {
      try terminal.setUseMetal(false)
    } catch {
      NSLog("MacScope could not configure terminal rendering: %@", error.localizedDescription)
    }
    return terminal
  }

  private func showStatus(message: String, detail: String, allowsRestart: Bool) {
    terminalView?.removeFromSuperview()
    terminalView = nil
    statusView?.removeFromSuperview()

    let title = NSTextField(labelWithString: message)
    title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
    title.textColor = .labelColor
    title.alignment = .center

    let description = NSTextField(wrappingLabelWithString: detail)
    description.font = NSFont.systemFont(ofSize: 13)
    description.textColor = .secondaryLabelColor
    description.alignment = .center
    description.maximumNumberOfLines = 3

    let stack = NSStackView(views: [title, description])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 8
    if allowsRestart {
      let restart = NSButton(
        title: "Restart",
        target: self,
        action: #selector(restartProcess)
      )
      restart.bezelStyle = .rounded
      restart.keyEquivalent = "\r"
      stack.addArrangedSubview(restart)
      stack.setCustomSpacing(16, after: description)
    }
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
    ])
    statusView = stack
  }

  @objc
  private func restartProcess() {
    startProcess()
  }
}
