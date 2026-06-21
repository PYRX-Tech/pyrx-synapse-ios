//
//  PyrxLogger.swift
//  PYRXSynapse
//
//  Thin OSLog-backed logger that respects a runtime `LogLevel` threshold.
//  Internal — not part of the public API. The `Pyrx` actor mutates its level
//  via `setLogLevel(_:)`.
//

import Foundation
import os.log

/// Internal logger. Routed through `os.log` so messages appear in Console.app
/// and Xcode's debug navigator with category `Synapse`.
final class PyrxLogger: @unchecked Sendable {
    static let shared = PyrxLogger()

    private let osLog: OSLog
    private let lock = NSLock()
    private var _level: LogLevel = .info

    private init() {
        self.osLog = OSLog(subsystem: "tech.pyrx.synapse", category: "Synapse")
    }

    var level: LogLevel {
        lock.lock()
        defer { lock.unlock() }
        return _level
    }

    func setLevel(_ level: LogLevel) {
        lock.lock()
        _level = level
        lock.unlock()
    }

    func debug(_ message: @autoclosure () -> String) {
        guard level <= .debug else { return }
        os_log("%{public}@", log: osLog, type: .debug, message())
    }

    func info(_ message: @autoclosure () -> String) {
        guard level <= .info else { return }
        os_log("%{public}@", log: osLog, type: .info, message())
    }

    func warning(_ message: @autoclosure () -> String) {
        guard level <= .warning else { return }
        os_log("%{public}@", log: osLog, type: .default, message())
    }

    func error(_ message: @autoclosure () -> String) {
        guard level <= .error else { return }
        os_log("%{public}@", log: osLog, type: .error, message())
    }
}
