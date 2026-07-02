import Foundation

// MARK: - Simple process-global logger

enum LogLevel: Int, Comparable, Sendable {
    case quiet = 0
    case normal = 1
    case verbose = 2

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

// Set once at program startup (before any TaskGroup is launched), so this is
// safe in practice despite being mutable global state.
nonisolated(unsafe) var globalLogLevel: LogLevel = .normal

func log(_ message: @autoclosure () -> String) {
    guard globalLogLevel >= .normal else { return }
    fputs("visionmd: \(message())\n", stderr)
}

func warn(_ message: @autoclosure () -> String) {
    // Warnings always printed (even in quiet mode).
    fputs("visionmd: warning: \(message())\n", stderr)
}

func verbose(_ message: @autoclosure () -> String) {
    guard globalLogLevel >= .verbose else { return }
    fputs("visionmd: \(message())\n", stderr)
}
