#if os(macOS)
import Foundation

nonisolated enum SSHAgentError: Error {
    case invalidMessage, unsupportedKey, invalidKey, unavailable
}

/// Length-prefixed SSH wire values. All inbound reads are bounded by the frame size.
nonisolated struct SSHWireReader {
    let data: Data
    private(set) var offset = 0
    var isAtEnd: Bool { offset == data.count }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw SSHAgentError.invalidMessage }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func uint32() throws -> UInt32 {
        try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    mutating func string() throws -> Data { try bytes(Int(uint32())) }
    mutating func text() throws -> String {
        guard let value = String(data: try string(), encoding: .utf8) else { throw SSHAgentError.invalidMessage }
        return value
    }
}

nonisolated enum SSHWire {
    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    static func string(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
    static func text(_ value: String) -> Data { string(Data(value.utf8)) }
}

nonisolated enum SSHAgentRequest {
    case identities
    case sign(publicKey: Data, message: Data, flags: UInt32)
    case unsupported

    static let maximumFrameSize = 256 * 1_024
    static let failure = Data([5])

    static func decode(_ payload: Data) throws -> SSHAgentRequest {
        guard !payload.isEmpty, payload.count <= maximumFrameSize else { throw SSHAgentError.invalidMessage }
        var reader = SSHWireReader(data: payload)
        switch try reader.byte() {
        case 11:
            guard reader.isAtEnd else { throw SSHAgentError.invalidMessage }
            return .identities
        case 13:
            let key = try reader.string()
            let message = try reader.string()
            let flags = try reader.uint32()
            guard reader.isAtEnd else { throw SSHAgentError.invalidMessage }
            return .sign(publicKey: key, message: message, flags: flags)
        default:
            // Includes add/remove keys, forwarding extensions, and legacy SSH1.
            return .unsupported
        }
    }

    static func identities(_ keys: [(blob: Data, name: String)]) -> Data {
        var response = Data([12]) + SSHWire.uint32(UInt32(keys.count))
        for key in keys { response += SSHWire.string(key.blob) + SSHWire.text(key.name) }
        return response
    }
    static func signature(algorithm: String, value: Data) -> Data {
        Data([14]) + SSHWire.string(SSHWire.text(algorithm) + SSHWire.string(value))
    }
}
#endif
