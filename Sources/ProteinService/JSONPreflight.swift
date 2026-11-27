import Foundation

struct JSONPreflight {
    enum Failure: Error {
        case invalidJSON, depthLimitExceeded, nodeLimitExceeded
    }

    static let maximumDepth = 32
    static let maximumNodes = 250_000

    static func isObject(_ data: Data) throws -> Bool {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var scanner = Self(bytes: bytes)
            return try scanner.scan()
        }
    }

    private let bytes: UnsafeRawBufferPointer
    private var index = 0
    private var nodes = 0

    private mutating func scan() throws -> Bool {
        skipWhitespace()
        let isObject = current == 123
        try scanValue(at: 1)
        guard current == nil else { throw Failure.invalidJSON }
        return isObject
    }

    private mutating func scanValue(at depth: Int) throws {
        guard let byte = current else { throw Failure.invalidJSON }
        guard depth <= Self.maximumDepth else { throw Failure.depthLimitExceeded }
        nodes += 1
        guard nodes <= Self.maximumNodes else { throw Failure.nodeLimitExceeded }
        switch byte {
        case 123: try scanContainer(at: depth, closing: 125, keyed: true)
        case 91: try scanContainer(at: depth, closing: 93, keyed: false)
        case 34: try skipString()
        case 45, 48...57: try skipNumber()
        case 102: try skipLiteral("false")
        case 110: try skipLiteral("null")
        case 116: try skipLiteral("true")
        default: throw Failure.invalidJSON
        }
        skipWhitespace()
    }

    private mutating func scanContainer(at depth: Int, closing: UInt8, keyed: Bool) throws {
        index += 1
        skipWhitespace()
        if consume(closing) { return }
        repeat {
            skipWhitespace()
            if keyed {
                guard current == 34 else { throw Failure.invalidJSON }
                try skipString()
                skipWhitespace()
                guard consume(58) else { throw Failure.invalidJSON }
                skipWhitespace()
            }
            try scanValue(at: depth + 1)
        } while consume(44)
        guard consume(closing) else { throw Failure.invalidJSON }
    }

    private mutating func skipNumber() throws {
        _ = consume(45)
        if !consume(48) { try skipDigits() }
        if consume(46) { try skipDigits() }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            try skipDigits()
        }
    }

    private mutating func skipDigits() throws {
        guard let byte = current, (48...57).contains(byte) else { throw Failure.invalidJSON }
        repeat { index += 1 } while current.map { (48...57).contains($0) } == true
    }

    private mutating func skipLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            guard consume(byte) else { throw Failure.invalidJSON }
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipString() throws {
        index += 1
        while let byte = current {
            index += 1
            switch byte {
            case 34:
                return
            case 92:
                guard let escaped = current else { throw Failure.invalidJSON }
                index += 1
                switch escaped {
                case 34, 47, 92, 98, 102, 110, 114, 116:
                    break
                case 117:
                    for _ in 0..<4 {
                        guard let digit = current, Self.isHexDigit(digit) else { throw Failure.invalidJSON }
                        index += 1
                    }
                default:
                    throw Failure.invalidJSON
                }
            case 0...31:
                throw Failure.invalidJSON
            default:
                break
            }
        }
        throw Failure.invalidJSON
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 {
            index += 1
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102: true
        default: false
        }
    }
}
