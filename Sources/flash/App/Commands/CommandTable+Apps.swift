import AppKit
import FlashCore

/// What the focused app does: `app`, `tab`, `pane`, `url`, `history`, `resource` and
/// `document`.
extension URLEventHandler {
  static let appsCommands: [String: CommandDefinition] = [
    "app reload": .init(
      "Reload the focused app's page; --force bypasses its cache", [.flag("force")],
      parse: { a in .reload(force: a.bool("force")) }),
    "app undo": .init(
      "Undo the last edit in the focused app", parse: { _ in .undo }),
    "app redo": .init(
      "Redo the last edit in the focused app", parse: { _ in .redo }),
    "resource archive": .init(
      "Archive the current item in the focused app", parse: { _ in .archive }),
    "resource next": .init(
      "Go to the next item in the focused app", parse: { _ in .resourceNext }),
    "resource previous": .init(
      "Go to the previous item in the focused app", parse: { _ in .resourcePrevious }),
    "tab close": .init(
      "Close the current tab", parse: { _ in .tabClose }),
    "app find": .init(
      "Open the focused app's Find", parse: { _ in .find }),
    "app find_next": .init(
      "Go to the next Find match in the focused app", parse: { _ in .findNext }),
    "app find_previous": .init(
      "Go to the previous Find match in the focused app", parse: { _ in .findPrevious }),
    "app switch": .init(
      "Open the flashlight on what is running", parse: { _ in .appSwitch }),
    "url copy": .init(
      "Copy the focused page's URL", parse: { _ in .copyURL }),
    "tab next": .init(
      "Select the next tab", parse: { _ in .tabNext }),
    "tab previous": .init(
      "Select the previous tab", parse: { _ in .tabPrev }),
    "tab first": .init(
      "Select the first tab", parse: { _ in .tabFirst }),
    "tab last": .init(
      "Select the last tab", parse: { _ in .tabLast }),
    "tab select": .init(
      "Select a tab by --index or the typed count", [.integer("index")],
      parse: { a in .tabSelect(index: a.int("index")) }),
    "tab move_previous": .init(
      "Move the current tab one place backward", parse: { _ in .tabMovePrev }),
    "tab move_next": .init(
      "Move the current tab one place forward", parse: { _ in .tabMoveNext }),
    "tab reopen": .init(
      "Reopen the last closed tab", parse: { _ in .tabReopen }),
    "pane next": .init(
      "Focus the next split pane", parse: { _ in .paneNext }),
    "pane previous": .init(
      "Focus the previous split pane", parse: { _ in .panePrev }),
    "pane split_vertical": .init(
      "Split the focused pane side by side", parse: { _ in .paneSplitVertical }),
    "pane split_horizontal": .init(
      "Split the focused pane top and bottom", parse: { _ in .paneSplitHorizontal }),
    "pane close": .init(
      "Close the focused split pane", parse: { _ in .paneClose }),
    "history back": .init(
      "Go back in the focused app", parse: { _ in .historyBack }),
    "history forward": .init(
      "Go forward in the focused app", parse: { _ in .historyForward }),
    "app previous": .init(
      "Focus the previous app", parse: { _ in .appPrev }),
    "app next": .init(
      "Focus the next app", parse: { _ in .appNext }),
    "app quit": .init(
      "Quit the focused app; --force force-quits it", [.flag("force")],
      parse: { a in .quitApp(force: a.bool("force")) }),
    "app save_and_quit": .init(
      "Save the focused document, then quit the app", [.flag("force")],
      parse: { a in .saveAndQuit(force: a.bool("force")) }),
    "app close": .init(
      "Close the current tab, else the focused window, quitting the app with its last window",
      parse: { _ in .appClose }),
    "tab new": .init(
      "Open a new tab", parse: { _ in .tabNew }),
    "app save": .init(
      "Save the focused document", parse: { _ in .save }),
    "app print": .init(
      "Print the focused document", parse: { _ in .print }),
    "document open": .init(
      "Open a document in the focused app", parse: { _ in .documentOpen }),
    "document save_as": .init(
      "Save the focused document under another name",
      parse: { a in a.args.isEmpty ? .documentSaveAs : nil }),
    "document export_pdf": .init(
      "Export the focused document as a PDF",
      parse: { a in a.args.isEmpty ? .documentExportPDF : nil }),
    "document revert": .init(
      "Revert the focused document to its last saved version, after asking",
      parse: { a in a.args.isEmpty ? .documentRevert : nil }),
    "document duplicate": .init(
      "Duplicate the focused document",
      parse: { a in a.args.isEmpty ? .documentDuplicate : nil }),
    "document rename": .init(
      "Rename the focused document", parse: { a in a.args.isEmpty ? .documentRename : nil }),
    "document page_setup": .init(
      "Open the focused document's page setup",
      parse: { a in a.args.isEmpty ? .documentPageSetup : nil }),
    "app look_up": .init(
      "Look up the word under the pointer in the focused app",
      parse: { a in a.args.isEmpty ? .lookUp : nil }),
    "app zoom_in": .init(
      "Zoom in with the focused app's own zoom", parse: { a in a.args.isEmpty ? .zoomIn : nil }),
    "app zoom_out": .init(
      "Zoom out with the focused app's own zoom", parse: { a in a.args.isEmpty ? .zoomOut : nil }),
    "app zoom_reset": .init(
      "Reset the focused app's zoom to actual size",
      parse: { a in a.args.isEmpty ? .zoomReset : nil }),
    "app view_source": .init(
      "Show the focused browser page's source",
      parse: { a in a.args.isEmpty ? .viewSource : nil }),
    "app settings": .init(
      "Open the focused app's settings", parse: { a in a.args.isEmpty ? .appSettings : nil }),
    "app select_all": .init(
      "Select everything in the focused app", parse: { a in a.args.isEmpty ? .selectAll : nil }),
    "app help": .init(
      "Open the focused app's Help menu", parse: { a in a.args.isEmpty ? .appHelp : nil }),
    "app cancel": .init(
      "Cancel in the focused app: close its popover, dialog or search",
      parse: { a in a.args.isEmpty ? .appCancel : nil }),
    "app stop": .init(
      "Stop loading the focused browser page", parse: { a in a.args.isEmpty ? .appStop : nil }),
    "app downloads": .init(
      "Show the focused browser's downloads", parse: { a in a.args.isEmpty ? .appDownloads : nil }),
    "app developer_tools": .init(
      "Open the focused browser's developer tools",
      parse: { a in a.args.isEmpty ? .developerTools : nil }),
    "app hide": .init(
      "Hide the focused app", parse: { a in a.args.isEmpty ? .appVisibility(.hide) : nil }),
    "app hide_others": .init(
      "Hide every app but the focused one",
      parse: { a in a.args.isEmpty ? .appVisibility(.hideOthers) : nil }),
    "app show_all": .init(
      "Show every hidden app", parse: { a in a.args.isEmpty ? .appVisibility(.showAll) : nil }),
    "app raise": .init(
      "Bring every window of the focused app to the front",
      parse: { a in a.args.isEmpty ? .appVisibility(.raise) : nil }),
    "url bookmark": .init(
      "Bookmark the focused page", parse: { a in a.args.isEmpty ? .urlBookmark : nil }),
    "url edit": .init(
      "Focus the focused browser's address bar", parse: { a in a.args.isEmpty ? .urlEdit : nil }),
    "history show": .init(
      "Show the focused browser's history", parse: { a in a.args.isEmpty ? .historyShow : nil }),
    "tab duplicate": .init(
      "Duplicate the current tab", parse: { a in a.args.isEmpty ? .tabDuplicate : nil }),
    "tab pin": .init(
      "Pin or unpin the current tab", parse: { a in a.args.isEmpty ? .tabPin : nil }),
    "tab mute": .init(
      "Mute or unmute the current tab", parse: { a in a.args.isEmpty ? .tabMute : nil }),
    "tab detach": .init(
      "Move the current tab to a new window", parse: { a in a.args.isEmpty ? .tabDetach : nil }),
    "app open": .init(
      "Open or focus an app by name", [.text("name", "app", required: true)],
      parse: { a in
        guard let name = a.value("name"), !name.isEmpty else { return nil }
        return .openApp(name: name)
      }),
  ]
}
