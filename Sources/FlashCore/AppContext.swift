import AppKit

public struct AppContext: @unchecked Sendable {
    public let bundleIdentifier: String
    public let processID: pid_t
    public let runningApp: NSRunningApplication
    public let frontWindowFrame: CGRect
    public let allScreensFrame: CGRect

    public init(
        bundleIdentifier: String,
        processID: pid_t,
        runningApp: NSRunningApplication,
        frontWindowFrame: CGRect,
        allScreensFrame: CGRect
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.runningApp = runningApp
        self.frontWindowFrame = frontWindowFrame
        self.allScreensFrame = allScreensFrame
    }
}
