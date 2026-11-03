import AppKit

/// `notes open`, `notes refresh` and their reminders and contacts twins.
/// `AppleCatalogs` reads the apps off main; this shows the result.
extension AppDelegate {
  func performAppleCatalogCommand(_ command: AppleCatalogCommand) {
    let diagnostic = URLCommand.appleCatalog(command).diagnosticDescription
    switch command {
    case .open(let catalog):
      openApplication(bundleID: catalog.bundleID, diagnostic: diagnostic)
    case .refresh(let catalog):
      appleCatalogs.refresh(catalog) { [weak self] outcome in
        switch outcome {
        case .listed, .cleared:
          self?.overlay.displayBanner("\(catalog.rawValue) refreshed")
        case .denied, .kept:
          // A refused or unanswered access request leaves the catalog empty,
          // without a banner.
          FlashLog.info("[apple] \(command.name) without \(catalog.appName) access")
        case .failed:
          self?.warnCommandFailure(diagnostic)
        }
      }
    }
  }

  /// The LaunchServices lookup runs off main; the open itself is
  /// asynchronous.
  private func openApplication(bundleID: String, diagnostic: String) {
    ApplicationLauncher.open(bundleID: bundleID) { [weak self] error in
      guard let error else { return }
      FlashLog.warn("[apple] \(diagnostic) failed: \(error)")
      self?.warnCommandFailure(diagnostic)
    }
  }
}
