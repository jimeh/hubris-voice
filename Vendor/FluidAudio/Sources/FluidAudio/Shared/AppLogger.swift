/// FluidAudio's logging facade, disabled by Hubris Voice to keep transcript and
/// vocabulary contents out of stderr and Unified Logging.
///
/// Modified from FluidAudio 0.15.7 by Hubris Voice. See
/// `third-party/vendor/README.md`, `third-party/vendor/sources.json`, and
/// `third-party/vendor/patches/fluidaudio/privacy-logging.patch` for provenance
/// and the complete patch.
public struct AppLogger: Sendable {
    nonisolated(unsafe) public static var defaultSubsystem: String = "com.fluidinference"

    public enum Level: Int, Sendable {
        case debug = 0
        case info
        case notice
        case warning
        case error
        case fault
    }

    public init(subsystem _: String, category _: String) {}

    public init(category _: String) {}

    public func debug(_: String) {}

    public func info(_: String) {}

    public func notice(_: String) {}

    public func warning(_: String) {}

    public func error(_: String) {}

    public func fault(_: String) {}
}
