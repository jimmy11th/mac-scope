import AppKit
import ApplicationServices
import Combine

enum MouseScrollReverserState: Equatable, Sendable {
  case disabled
  case active
  case permissionRequired
  case unavailable
}

// The event tap is installed on the main run loop and every public call is made by MainActor UI code.
final class MouseScrollReverser: ObservableObject, @unchecked Sendable {
  @Published private(set) var state: MouseScrollReverserState = .disabled

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var shouldBeEnabled = false

  deinit {
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
  }

  func setEnabled(_ enabled: Bool, requestPermission: Bool = false) {
    shouldBeEnabled = enabled
    guard enabled else {
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
      state = .disabled
      return
    }

    if !hasInputMonitoringPermission {
      if requestPermission {
        _ = CGRequestListenEventAccess()
      }
      guard hasInputMonitoringPermission else {
        state = .permissionRequired
        return
      }
    }

    if eventTap == nil, !installEventTap() {
      state = .unavailable
      return
    }
    if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    state = .active
  }

  func refreshPermission() {
    guard shouldBeEnabled else {
      state = .disabled
      return
    }
    setEnabled(true)
  }

  func openInputMonitoringSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private var hasInputMonitoringPermission: Bool {
    CGPreflightListenEventAccess()
  }

  private func installEventTap() -> Bool {
    let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
    let callback: CGEventTapCallBack = { _, type, event, userInfo in
      guard let userInfo else { return Unmanaged.passUnretained(event) }
      let reverser = Unmanaged<MouseScrollReverser>.fromOpaque(userInfo).takeUnretainedValue()

      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap = reverser.eventTap {
          CGEvent.tapEnable(tap: eventTap, enable: reverser.shouldBeEnabled)
        }
        return Unmanaged.passUnretained(event)
      }

      guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
      // macOS marks trackpad momentum and gesture events as continuous. Leave those untouched.
      guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
        return Unmanaged.passUnretained(event)
      }

      let fields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1,
        .scrollWheelEventDeltaAxis2,
        .scrollWheelEventDeltaAxis3,
        .scrollWheelEventPointDeltaAxis1,
        .scrollWheelEventPointDeltaAxis2,
        .scrollWheelEventPointDeltaAxis3,
        .scrollWheelEventFixedPtDeltaAxis1,
        .scrollWheelEventFixedPtDeltaAxis2,
        .scrollWheelEventFixedPtDeltaAxis3,
      ]
      for field in fields {
        let value = event.getIntegerValueField(field)
        if value != 0 { event.setIntegerValueField(field, value: -value) }
      }
      return Unmanaged.passUnretained(event)
    }

    let userInfo = Unmanaged.passUnretained(self).toOpaque()
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: callback,
        userInfo: userInfo
      )
    else { return false }

    self.eventTap = eventTap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    return true
  }
}
