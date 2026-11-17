import AppKit

/// `[tiling]`: the `tile` and `workspace` commands run on the window layout
/// queue (`TilingEngine`); their outcomes and the workspace state come back
/// here, on main.
extension AppDelegate {
  /// A command's outcome: the CLI and the command line get it as text; a
  /// mapping shows a failure or a listing as a banner.
  func finishTiling(
    _ outcome: TilingOutcome, completion: ((NormalModeCommandOutcome, String?) -> Void)?
  ) {
    switch outcome {
    case .done:
      completion?(.performed, nil)
    case .output(let text):
      if let completion { completion(.performed, text) } else { overlay.displayBanner(text) }
    case .failed(let reason):
      FlashLog.info("[tiling] command_failed", fields: ["reason": reason])
      if let completion { completion(.failed, reason) } else { overlay.displayBanner(reason) }
    }
  }

  /// The workspaces changed: `#{flash.workspace}`, `#{flash.workspaces}`,
  /// and `core:workspace.changed` when the focused one did. nil: tiling
  /// stopped.
  func tilingStatusDidChange(_ status: TilingStatus?) {
    let before = lastTilingStatus
    lastTilingStatus = status
    statusBarController?.updateWorkspaces(
      focused: status?.focused ?? "", listed: status?.listed ?? [])
    guard let status, let payload = status.workspaceChange(since: before) else { return }
    FlashLog.debug(
      "[tiling] workspace_changed",
      fields: ["workspace": status.focused ?? "-", "previous": status.previous ?? "-"])
    emitHostEvent(PluginEvent(.workspaceChanged, payload: payload))
  }
}
