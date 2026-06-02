import CoreGraphics

public struct JumpTarget: @unchecked Sendable {
    public let id: String
    public let frame: CGRect
    public let role: String?
    public let accessibilityLabel: String?
    public let activate: ((JumpAction) -> Bool)?
    public let providerID: String

    public init(
        id: String,
        frame: CGRect,
        role: String? = nil,
        accessibilityLabel: String? = nil,
        activate: ((JumpAction) -> Bool)? = nil,
        providerID: String
    ) {
        self.id = id
        self.frame = frame
        self.role = role
        self.accessibilityLabel = accessibilityLabel
        self.activate = activate
        self.providerID = providerID
    }
}
