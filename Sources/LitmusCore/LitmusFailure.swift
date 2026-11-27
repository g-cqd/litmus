/// A failure that invalidates an operation rather than manufacturing a partial success.
public struct LitmusFailure: Error, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
