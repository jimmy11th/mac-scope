import Foundation

public enum ProcessTermination: Equatable {
  case exited(Int32)
  case signaled(Int32)
  case unavailable

  public init(waitStatus: Int32?) {
    guard let waitStatus else {
      self = .unavailable
      return
    }
    let signal = waitStatus & 0x7f
    if signal == 0 {
      self = .exited((waitStatus >> 8) & 0xff)
    } else {
      self = .signaled(signal)
    }
  }

  public var succeeded: Bool {
    self == .exited(0)
  }

  public var displayDescription: String {
    switch self {
    case .exited(let code):
      "Exit code \(code)"
    case .signaled(let signal):
      "Terminated by signal \(signal)"
    case .unavailable:
      "The process ended unexpectedly"
    }
  }
}
