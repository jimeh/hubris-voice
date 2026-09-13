import Foundation

public struct ReconnectPolicy: Equatable, Sendable {
  public var initialDelay: Duration
  public var multiplier: Double
  public var maximumDelay: Duration

  public init(
    initialDelay: Duration = .milliseconds(500),
    multiplier: Double = 2,
    maximumDelay: Duration = .seconds(30)
  ) {
    self.initialDelay = initialDelay
    self.multiplier = multiplier
    self.maximumDelay = maximumDelay
  }

  public func delay(forAttempt attempt: Int) -> Duration {
    precondition(attempt >= 1)
    let scale = pow(multiplier, Double(attempt - 1))
    let initialSeconds = initialDelay.timeInterval
    let maximumSeconds = maximumDelay.timeInterval
    return .seconds(min(initialSeconds * scale, maximumSeconds))
  }
}

private extension Duration {
  var timeInterval: TimeInterval {
    let components = components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1e18
  }
}
