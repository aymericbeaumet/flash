import Foundation

public protocol JumpProvider: AnyObject {
    var identifier: String { get }
    var priority: Int { get }
    func supports(_ context: AppContext) -> Bool
    func discover(in context: AppContext, deadline: Date) throws -> [JumpTarget]
}
