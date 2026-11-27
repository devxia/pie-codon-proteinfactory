import Foundation

public struct BoundedResponseBody: Sendable {
    public static let maximumBytes = 1_048_576

    private(set) var data: Data? = Data()

    public init() {}

    @discardableResult
    public mutating func append(_ chunk: Data) -> Bool {
        guard let count = data?.count else { return false }
        guard chunk.count <= Self.maximumBytes - count else {
            data = nil
            return false
        }
        data?.append(chunk)
        return true
    }
}
