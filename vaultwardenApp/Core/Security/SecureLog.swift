import Foundation
import OSLog

nonisolated enum SecureLog {
    static let sync = Logger(subsystem: subsystem, category: "Sync")
    static let autofill = Logger(subsystem: subsystem, category: "AutoFill")
    static let send = Logger(subsystem: subsystem, category: "Send")
    static let background = Logger(subsystem: subsystem, category: "Background")
    static let crypto = Logger(subsystem: subsystem, category: "Crypto")
    static let security = Logger(subsystem: subsystem, category: "Security")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "VaultwardenApp"

    static func failure(_ operation: String, error: any Error, logger: Logger) {
#if DEBUG
        let errorType = String(reflecting: type(of: error))
        logger.error("\(operation, privacy: .public) failed; error-type=\(errorType, privacy: .private(mask: .hash))")
#endif
    }

    static func event(_ message: String, logger: Logger) {
#if DEBUG
        logger.debug("\(message, privacy: .public)")
#endif
    }
}
