import ApplicationServices

enum PermissionCheck {
    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }
}
