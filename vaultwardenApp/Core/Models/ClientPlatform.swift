import Foundation

/// Platform identity used consistently for login and token refresh.
nonisolated enum ClientPlatform {
    /// Protocol compatibility, independent of this community app's bundle version.
    /// Vaultwarden omits SSH ciphers from /sync without a version >= 2024.12.0.
    static let bitwardenCompatibilityVersion = "2024.12.0"

    #if os(macOS)
    static let clientID = "desktop"
    static let deviceType = "7"
    static let deviceName = "Mac"
    static let userAgent = "vaultwardenApp/macOS"
    static let encryptedFileWritingOptions: Data.WritingOptions = [.atomic]
    static let protectedFileWritingOptions: Data.WritingOptions = [.atomic]
    #else
    static let clientID = "mobile"
    static let deviceType = "1"
    static let deviceName = "iPhone"
    static let userAgent = "vaultwardenApp/iOS"
    static let encryptedFileWritingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    static let protectedFileWritingOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
    #endif
}
