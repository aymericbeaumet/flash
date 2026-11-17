# Commands

Every Flash command is two words, a topic and an action:
`flash <topic> <action> [--name=value ...]`. The topic is what the command
acts on (`tab`, `window`, `mouse`), the action what happens to it (`next`,
`move`, `target`). Both are lowercase words of `[a-z][a-z0-9_]*`; an action
keeps an underscore only when it needs two words (`scroll half_page_down`).
Arguments are `--name=value` for values and bare flags such as `--secondary`
for booleans.

The same words work everywhere: from a terminal (`flash tab next`), in a
mapping (`["flash", "tab", "next"]`), and in the command line (`:tab next`),
where `Tab` completes the topic, then its action. `:` opens the command line
in NORMAL (`mode command`). There, `:commands` opens the installed command
inventory, `:help` or `flash help show` opens the browser help homepage, and
`?`, `:mappings` or `flash mappings show` opens the live mapping reference.

`flash <words>` in a terminal is exactly `:<words>` in the command line: the
resident resolves the words with the same resolver against the same commands
(the focused app's plugin commands included) and runs them through the same
runner. The CLI reaches the resident over its local socket, starting Flash
first when it is not running; scripts may speak that socket directly
([IPC protocol](ipc-protocol.md)). Both take the [abbreviations](#command-line-abbreviations), the
[vim aliases](#vim-command-line-aliases), `open <args>`, `flashlight <query>`,
`doctor`, the queries below and the `#` prefix that also
copies the output to the clipboard (`flash '#tab' next`, `:#aws whoami`).
Each surface presents the result its own way: the CLI prints the output and
exits 0 when the command ran, 1 when it failed or found nothing to act on (an
app with no such command, no app to act in), and 2 when the words name no
command or more than one, saying which; `flash --json <words>` prints the
same reply as one JSON object (`status`, `output`, `message`) with the same
exit status; the command line shows a one-line output on a banner and a
longer one in the pager. A command that asks for
confirmation counts as run once the question is up. Only mappings and config
files require exact words. The live [command catalog](/commands) lists every built-in and
installed plugin command with its arguments; [hints](hints.md) and the
[mouse grid](mouse-grid.md) walk through the mouse commands, and
[mapping syntax](mappings.md) the TOML around a mapping. The app's own
operations — print, save as, export, revert, settings, a browser's
bookmarks and history — and `menu press`, which presses any menu item by
its titles, are in [app operations](normal-mode.md#app-operations).

Plugin commands have the same shape, `flash <command> <subcommand> [word ...]`
(`flash tmux session main`, `flash screenshot window`), and share the topic
namespace: a topic word never becomes a plugin's own command, and a manifest
whose command or subcommand is not a `[a-z][a-z0-9_]*` word (or the `*`
wildcard subcommand) fails to load. A plugin may instead list one of Flash's
own commands in its `commands[]` (`tab close`) to perform it where its
selector matches; see [source commands](normal-mode.md#source-commands).

## Command reference

| Command | What it does |
| --- | --- |
| `about show` | Open the About Flash window |
| `alert confirm --prompt=<question> --command=<topic action [--arg=value ...]>` | Ask first, then run the wrapped command on y |
| `alert dismiss` | Dismiss the alert |
| `alert show --message=<text> [--duration=<seconds>] [--style=<standard|warning|error>]` | Show a message in the centred alert |
| `app cancel` | Cancel in the focused app: close its popover, dialog or search |
| `app close` | Close the current tab, else the focused window, quitting the app with its last window |
| `app developer_tools` | Open the focused browser's developer tools |
| `app downloads` | Show the focused browser's downloads |
| `app find` | Open the focused app's Find |
| `app find_next` | Go to the next Find match in the focused app |
| `app find_previous` | Go to the previous Find match in the focused app |
| `app help` | Open the focused app's Help menu |
| `app hide` | Hide the focused app |
| `app hide_others` | Hide every app but the focused one |
| `app look_up` | Look up the word under the pointer in the focused app |
| `app next` | Focus the next app |
| `app open --name=<app>` | Open or focus an app by name |
| `app previous` | Focus the previous app |
| `app print` | Print the focused document |
| `app quit [--force]` | Quit the focused app; --force force-quits it |
| `app raise` | Bring every window of the focused app to the front |
| `app redo` | Redo the last edit in the focused app |
| `app reload [--force]` | Reload the focused app's page; --force bypasses its cache |
| `app save` | Save the focused document |
| `app save_and_quit [--force]` | Save the focused document, then quit the app |
| `app select_all` | Select everything in the focused app |
| `app settings` | Open the focused app's settings |
| `app show_all` | Show every hidden app |
| `app stop` | Stop loading the focused browser page |
| `app switch` | Open the flashlight on what is running |
| `app undo` | Undo the last edit in the focused app |
| `app view_source` | Show the focused browser page's source |
| `app zoom_in` | Zoom in with the focused app's own zoom |
| `app zoom_out` | Zoom out with the focused app's own zoom |
| `app zoom_reset` | Reset the focused app's zoom to actual size |
| `appearance toggle` | Switch between light and dark appearance |
| `appwindows hide` | Close App Exposé |
| `appwindows show` | Show the focused app's windows (App Exposé) |
| `appwindows toggle` | Show the focused app's windows, or close App Exposé |
| `audio input [--device=<name-or-uid>]` | List the input devices, or select one with --device |
| `audio output [--device=<name-or-uid>]` | List the output devices, or select one with --device |
| `caffeinate off` | Let the Mac sleep again |
| `caffeinate on [--minutes=<n>]` | Keep the Mac awake, for --minutes or until caffeinate off |
| `caffeinate status` | Show whether the Mac is kept awake |
| `caffeinate toggle [--minutes=<n>]` | Keep the Mac awake, or let it sleep again |
| `calendar join` | Open the meeting link of the next or current calendar event |
| `calendar next` | Show the next calendar event |
| `clipboard copy` | Copy with the focused app's copy command |
| `clipboard delete --id=<entry-id>` | Delete one clipboard history entry |
| `clipboard paste` | Paste with the focused app's paste command |
| `clipboard pin --id=<entry-id>` | Pin one clipboard history entry: it lists first and is never trimmed |
| `clipboard restore --id=<entry-id> [--paste] [--plain]` | Put a clipboard history entry back on the clipboard; --paste pastes it, --plain keeps only its text |
| `clipboard show [--offset=<0..10000>]` | Open the clipboard history |
| `clipboard unpin --id=<entry-id>` | Unpin one clipboard history entry |
| `commands show` | Open the command catalog |
| `config edit` | Open the configuration file in its default app |
| `config reload` | Re-read the configuration file now |
| `contacts open` | Open Contacts |
| `contacts refresh` | Relist your contacts in @contacts now |
| `controlcenter hide` | Close Control Center |
| `controlcenter show` | Open Control Center |
| `controlcenter toggle` | Open or close Control Center |
| `cursor big_word_end` | Move to the end of this or the next blank-separated word (E) |
| `cursor column` | Move to the column the count names on the line |
| `cursor first_line` | Move to the first line's first non-blank character (gg) |
| `cursor first_nonblank` | Move to the line's first non-blank character (^) |
| `cursor last_line` | Move to the last line's first non-blank character (G) |
| `cursor last_nonblank` | Move to the line's last non-blank character, count - 1 lines down (g_) |
| `cursor line [--index=<n>] [--percent=<n>]` | Move to line --index, or --percent of the way through the text ({count}G, {count}%) |
| `cursor line_end` | Move to the line's last character, count - 1 lines down ($) |
| `cursor line_nonblank` | Move to the first non-blank character, count - 1 lines down (_) |
| `cursor line_start` | Move to the first character of the line (0) |
| `cursor matching_bracket` | Move to the bracket matching the next one on the line (%) |
| `cursor next_big_word` | Move to the start of the next blank-separated word (W) |
| `cursor next_char [--char=<c>]` | Move onto the next occurrence of a character on the line (f); without --char, the next key typed |
| `cursor next_line` | Move to the next line's first non-blank character (+, Return) |
| `cursor next_paragraph` | Move to the next empty line (}) |
| `cursor next_sentence` | Move to the start of the next sentence ()) |
| `cursor next_word` | Move to the start of the next word (w) |
| `cursor previous_big_word` | Move to the start of this or the previous blank-separated word (B) |
| `cursor previous_big_word_end` | Move to the end of the previous blank-separated word (gE) |
| `cursor previous_char [--char=<c>]` | Move onto the previous occurrence of a character on the line (F); without --char, the next key typed |
| `cursor previous_line` | Move to the previous line's first non-blank character (-) |
| `cursor previous_paragraph` | Move to the previous empty line ({) |
| `cursor previous_sentence` | Move to the start of this or the previous sentence (() |
| `cursor previous_word` | Move to the start of this or the previous word (b) |
| `cursor previous_word_end` | Move to the end of the previous word (ge) |
| `cursor repeat_char` | Repeat the last character search on the line (;) |
| `cursor repeat_char_back` | Repeat the last character search the other way (,) |
| `cursor screen_bottom` | Move to the last line on screen, or the count-th from it (L) |
| `cursor screen_middle` | Move to the middle line on screen (M) |
| `cursor screen_top` | Move to the first line on screen, or the count-th (H) |
| `cursor till_next_char [--char=<c>]` | Move just before the next occurrence of a character on the line (t); without --char, the next key typed |
| `cursor till_previous_char [--char=<c>]` | Move just after the previous occurrence of a character on the line (T); without --char, the next key typed |
| `cursor word_end` | Move to the end of this or the next word (e) |
| `desktop hide` | Bring the windows back over the desktop |
| `desktop show` | Show the desktop, moving every window aside |
| `desktop toggle` | Show the desktop, or bring the windows back |
| `display sleep` | Turn the displays off |
| `document duplicate` | Duplicate the focused document |
| `document export_pdf` | Export the focused document as a PDF |
| `document open` | Open a document in the focused app |
| `document page_setup` | Open the focused document's page setup |
| `document rename` | Rename the focused document |
| `document revert` | Revert the focused document to its last saved version, after asking |
| `document save_as` | Save the focused document under another name |
| `help show [--topic=<topic>]` | Open Flash's help, or a documentation page with --topic |
| `hints dismiss` | Dismiss hint labels |
| `history back` | Go back in the focused app |
| `history forward` | Go forward in the focused app |
| `history show` | Show the focused browser's history |
| `input char_left` | Move the cursor one character left in the focused text |
| `input char_right` | Move the cursor one character right in the focused text |
| `input document_end` | Move the cursor to the end of the focused text |
| `input document_start` | Move the cursor to the start of the focused text |
| `input focus` | Focus an editable field in the focused window, keeping the mode |
| `input line_down` | Move the cursor down a line in the focused text |
| `input line_end` | Move the cursor to the end of its line in the focused text |
| `input line_start` | Move the cursor to the start of its line in the focused text |
| `input line_up` | Move the cursor up a line in the focused text |
| `input select_document_end` | Extend the selection to the text's end with the app's own key |
| `input select_document_start` | Extend the selection to the text's start with the app's own key |
| `input select_down` | Extend the selection a line down with the app's own key |
| `input select_left` | Extend the selection a character left with the app's own key |
| `input select_line_end` | Extend the selection to the line's end with the app's own key |
| `input select_line_start` | Extend the selection to the line's start with the app's own key |
| `input select_right` | Extend the selection a character right with the app's own key |
| `input select_up` | Extend the selection a line up with the app's own key |
| `input select_word_left` | Extend the selection a word left with the app's own key |
| `input select_word_right` | Extend the selection a word right with the app's own key |
| `key arrow --direction=<left|down|up|right> [--shift]` | Press one arrow key; --shift holds Shift |
| `key function --key=<f1>` | Press a plain F1–F20 key |
| `key send --keys=<hotkey>` | Send one keystroke to the focused app |
| `key sequence --keys=<hotkey,hotkey,...>` | Send a short key sequence to the focused app |
| `key system --key=<brightness_down>` | Press an Apple function-row key (media_play, brightness_down, …) |
| `launchpad hide` | Close the Apps view (Launchpad before macOS 26) |
| `launchpad show` | Open the Apps view (Launchpad before macOS 26) |
| `launchpad toggle` | Open or close the Apps view (Launchpad before macOS 26) |
| `logs show` | Open the logs page |
| `logs write --message=<text> [--trace] [--debug] [--info] [--warn] [--error] [--area=<area>] [--fields=<key=value,...>]` | Write a line to Flash's log, at info or the level flag given |
| `macro play [--register=<name>]` | Replay a macro register, or the last one played (@{reg}, @@) |
| `macro record --register=<name>` | Record the commands that follow into a register (q{reg}) |
| `macro repeat [--count=<n>]` | Run the last NORMAL command again (.), --count times instead of its own count ({count}.) |
| `macro stop` | Stop recording the macro |
| `mappings show` | Open the mappings page for the focused app |
| `mark jump --letter=<a-z|0-9>` | Bring back the app saved under a letter or digit |
| `mark set --letter=<a-z|0-9>` | Save the focused app under one letter or digit |
| `media status` | Show what the media apps are playing and the volume |
| `menu choose --file=<path> [--prompt=<label>]` | Pick a line of --file in the flashlight and answer with it; for scripts, like dmenu |
| `menu press --path=<Menu,Item,...>` | Press a menu-bar item of the focused app by its titles, comma-separated |
| `metrics record --name=<metric> --value=<number> [--kind=<gauge|counter|histogram>] [--unit=<unit>] [--attributes=<key=value,...>]` | Record a gauge, counter or histogram value into Flash's metrics |
| `missioncontrol hide` | Close Mission Control |
| `missioncontrol show` | Open Mission Control |
| `missioncontrol toggle` | Open or close Mission Control |
| `mode command [--input=<text>] [--restore-mode]` | Open the command line, optionally pre-filled with --input |
| `mode flashlight [--query=<text>] [--restore-mode]` | Open the flashlight, optionally pre-filled with --query (a @type, a !bang or text) |
| `mode hold [--secondary] [--middle]` | Grab what is under the pointer (HOLD), or drop it |
| `mode insert` | Enter INSERT mode: keys go to the focused app |
| `mode layer --name=<layer>` | Enter a layer: its own keys act until Escape or mode leave |
| `mode leave` | Leave the current mode: INSERT, a layer, the command line or a popup |
| `mode normal` | Enter NORMAL mode |
| `mode terminal [--name=<popup>]` | Show and focus a popup; without --name, the terminal popup |
| `mode visual [--line] [--reselect]` | Select from the cursor in the focused text (VISUAL); --line selects whole lines; again, leave it; --reselect selects the last VISUAL range again (gv) |
| `monitors show` | Open the monitors page |
| `mouse bigram [--secondary] [--double] [--middle] [--triple] [--move] [--gesture=<look_up|smart_zoom>] [--modifiers=<cmd+ctrl+alt+shift>]` | Type a visible character, then its hint, and click that glyph |
| `mouse button --state=<down|up|toggle|release|cancel> [--secondary] [--middle] [--mode=<hold>]` | Press, release or toggle a mouse button at the pointer |
| `mouse dock` | Label the Dock's items |
| `mouse gesture --fingers=<2|3|4|5> --motion=<tap|double_tap|pinch|spread|rotate_left|rotate_right|swipe_left|swipe_right|swipe_up|swipe_down>` | Perform a trackpad gesture at the pointer |
| `mouse grid [--secondary] [--double] [--middle] [--triple] [--move] [--drag] [--select] [--multi] [--gesture=<look_up|smart_zoom>] [--modifiers=<cmd+ctrl+alt+shift>] [--bisect] [--zoom-to-depth=<n>]` | Pick any screen position on a keyboard-shaped grid |
| `mouse menubar` | Label the focused app's menus and the menu-bar status items |
| `mouse notifications` | Label Notification Center's banners, alerts and buttons |
| `mouse nudge --direction=<up|down|left|right> [--distance=<points>]` | Move the pointer, and a held drag, a few points |
| `mouse pointer` | Move the pointer from the keyboard |
| `mouse position --action=<save|unsave|clear|hints|next|previous> [--secondary] [--double] [--middle] [--triple] [--move] [--modifiers=<cmd+ctrl+alt+shift>]` | Save, label, cycle or forget saved pointer positions |
| `mouse repeat` | Click again where Flash last clicked |
| `mouse screens [--index=<n>] [--direction=<next|previous>] [--to=<center|last>] [--focus]` | Label each display by its number and move the pointer to the one you pick |
| `mouse step [--direction=<up|down|left|right>] [--to=<next_word|previous_word|word_end|line_start|line_end>]` | Move the pointer one text line or character, or jump a word or line |
| `mouse target [--secondary] [--double] [--middle] [--triple] [--move] [--drag] [--select] [--multi] [--adjust] [--search] [--path] [--sticky] [--copy-url] [--copy-text] [--gesture=<look_up|smart_zoom>] [--modifiers=<cmd+ctrl+alt+shift>] [--scope=<app|screen>] [--words]` | Label the focused window's targets and click the one you pick |
| `mouse warp [--area=<window|screen>] [--edge=<center|top|bottom|left|right>]` | Move the pointer to an edge or the centre of the window or screen |
| `move bottom` | Move to the end of the text, the last item where the app says, or the bottom |
| `move down` | Move down: the caret in text, the selection in a list, else scroll |
| `move half_page_down` | Move down by [mode] move_page_lines arrows, or scroll half a page |
| `move half_page_up` | Move up by [mode] move_page_lines arrows, or scroll half a page |
| `move left` | Move left: the caret within its line, the selection in a list, else scroll |
| `move page_down` | Move down by twice move_page_lines arrows, or a page |
| `move page_up` | Move up by twice move_page_lines arrows, or a page |
| `move right` | Move right: the caret within its line, the selection in a list, else scroll |
| `move top` | Move to the start of the text, the first item where the app says, or the top |
| `move up` | Move up: the caret in text, the selection in a list, else scroll |
| `movement back` | Jump back through Flash's movement history |
| `movement forward` | Jump forward through Flash's movement history |
| `notes open` | Open Notes |
| `notes refresh` | Relist your notes in @notes now |
| `notificationcenter hide` | Close Notification Center |
| `notificationcenter show` | Open Notification Center |
| `notificationcenter toggle` | Open or close Notification Center |
| `notify clear [--id=<id>]` | Remove Flash's notifications from Notification Center, or the one --id names |
| `notify send [--title=<text>] [--subtitle=<text>] [--body=<text>] [--sound] [--url=<url>] [--command=<topic action [--arg=value ...]>] [--id=<id>]` | Post a macOS notification; a click can open --url or run --command |
| `pane close` | Close the focused split pane |
| `pane next` | Focus the next split pane |
| `pane previous` | Focus the previous split pane |
| `pane split_horizontal` | Split the focused pane top and bottom |
| `pane split_vertical` | Split the focused pane side by side |
| `plugins reload` | Stop and restart every loaded plugin |
| `plugins show` | Open the plugins page |
| `popup quit [--name=<popup>]` | Quit the focused or named popup's process; persistent popups restart |
| `popup restart [--name=<popup>]` | Restart the focused or named popup's process |
| `process kill --pid=<n>` | Terminate one process, after asking |
| `register paste [--register=<name>] [--after]` | Paste a register with the app's own paste; --after first steps past the character under the cursor, as vim's p |
| `register yank [--register=<name>]` | Copy the focused app's selection into a register |
| `reminders open` | Open Reminders |
| `reminders refresh` | Relist your open reminders in @reminders now |
| `resident quit` | Quit Flash |
| `resource archive` | Archive the current item in the focused app |
| `resource next` | Go to the next item in the focused app |
| `resource previous` | Go to the previous item in the focused app |
| `screen lock` | Lock the screen |
| `screensaver start` | Start the screen saver |
| `scroll bottom` | Scroll to the bottom |
| `scroll cursor_bottom` | Scroll the focused text so the cursor's line sits at the bottom (zb) |
| `scroll cursor_middle` | Scroll the focused text so the cursor's line sits in the middle (zz) |
| `scroll cursor_top` | Scroll the focused text so the cursor's line sits at the top (zt) |
| `scroll down` | Scroll down [mode] scroll_step_lines lines |
| `scroll half_page_down` | Scroll down half a page |
| `scroll half_page_up` | Scroll up half a page |
| `scroll left` | Scroll left |
| `scroll line_down` | Scroll down one line, the count that many (ctrl+e) |
| `scroll line_up` | Scroll up one line, the count that many (ctrl+y) |
| `scroll page_down` | Scroll down a page |
| `scroll page_up` | Scroll up a page |
| `scroll right` | Scroll right |
| `scroll target` | Pick the scroll area the scroll commands drive |
| `scroll top` | Scroll to the top |
| `scroll up` | Scroll up [mode] scroll_step_lines lines |
| `selection copy [--register=<name>]` | Copy the selected text, ending HOLD or VISUAL |
| `selection paste [--register=<name>]` | Paste over the selected text, ending HOLD or VISUAL |
| `selection swap_ends` | Move VISUAL's moving end to the other end of the selection (o) |
| `startup run` | Run the [startup] commands again, in order, and list how each ended |
| `status clear --name=<source>` | Clear the value pushed into a [statusbar.sources] source |
| `status refresh --name=<source>` | Run a [statusbar.sources] source's command now instead of at its interval |
| `status set --name=<source> --value=<text>` | Push a value into a [statusbar.sources] source from a script or hook |
| `system logout` | Log out, after asking |
| `system restart` | Restart the Mac, after asking |
| `system shutdown` | Shut the Mac down, after asking |
| `system sleep` | Sleep the Mac |
| `tab close` | Close the current tab |
| `tab detach` | Move the current tab to a new window |
| `tab duplicate` | Duplicate the current tab |
| `tab first` | Select the first tab |
| `tab last` | Select the last tab |
| `tab move_next` | Move the current tab one place forward |
| `tab move_previous` | Move the current tab one place backward |
| `tab mute` | Mute or unmute the current tab |
| `tab new` | Open a new tab |
| `tab next` | Select the next tab |
| `tab pin` | Pin or unpin the current tab |
| `tab previous` | Select the previous tab |
| `tab reopen` | Reopen the last closed tab |
| `tab select [--index=<n>]` | Select a tab by --index or the typed count |
| `telemetry show` | Open the telemetry page |
| `tile balance` | Give every tiled window of the focused workspace an equal share |
| `tile flatten` | Put every tiled window of the focused workspace in one container |
| `tile float` | Float the focused window, or tile it again |
| `tile fullscreen` | Make the focused tiled window fill its workspace, or end it |
| `tile join --direction=<left|right|up|down>` | Put the focused tiled window and its neighbor in a new container |
| `tile layout --type=<tiles|accordion|horizontal|vertical|toggle>` | Set the focused window's container to tiles or accordion, horizontal or vertical |
| `tile move --direction=<left|right|up|down>` | Move the focused tiled window in a direction in its workspace's tree |
| `tile resize --dimension=<width|height|smart> --amount=<points>` | Grow or shrink the focused tiled window by points |
| `tile swap --direction=<left|right|up|down>` | Swap the focused tiled window with its neighbor in a direction |
| `trash empty` | Empty the Trash, after asking |
| `updates check` | Check GitHub for a newer Flash and say what installing it means |
| `updates install` | Download, verify and install the newest Flash, then restart it |
| `url bookmark` | Bookmark the focused page |
| `url copy` | Copy the focused page's URL |
| `url edit` | Focus the focused browser's address bar |
| `volume down` | Lower the output volume one step |
| `volume mute` | Mute or unmute the output |
| `volume up` | Raise the output volume one step |
| `window close` | Close the focused window |
| `window close_all` | Close every window of the focused app, after asking |
| `window focus --direction=<left|right|up|down|next|previous|behind>` | Focus the nearest window in a direction, or cycle the stack |
| `window fullscreen [--state=<on|off|toggle>]` | Toggle, enter or leave native full screen |
| `window last` | Focus the window you were in before this one |
| `window minimize` | Minimize the focused window |
| `window move [--position=<slot>] [--x=<percent>] [--y=<percent>] [--width=<percent>] [--height=<percent>] [--screen=<n>]` | Tile, resize or move the focused window |
| `window new [--private]` | Open a new window; --private, a private browsing one |
| `window next` | Focus the focused app's next window |
| `window previous` | Focus the focused app's previous window |
| `window restore` | Restore the most recently minimized window |
| `window switch` | Pick any window, most recently used first; again to move down the list |
| `window zoom` | Zoom the focused window to fit its content, or back |
| `workspace back_and_forth` | Show the workspace focused before this one |
| `workspace list` | List the workspaces, their windows and displays, the focused one marked |
| `workspace move_to_monitor --direction=<next|previous>` | Show the focused workspace on the next or previous display |
| `workspace move_window --name=<workspace>` | Move the focused window to a workspace |
| `workspace next` | Show the next workspace on the focused display |
| `workspace previous` | Show the previous workspace on the focused display |
| `workspace switch --name=<workspace>` | Show a workspace and focus it; created on demand |

## Command-line abbreviations

In the command line, each word may be cut to any prefix that is unambiguous
at its position among the commands available right now: Flash's topics and
the loaded plugins' commands, then that topic's actions or that command's
subcommands. `:ta nex` is `tab next`, `:mou g` is `mouse grid` and
`:screensh w` is `screenshot window`. An exact word wins over a longer one
it prefixes, so `:tab new` is `tab new` even though `next` shares two letters.
Flags are never abbreviated: `--direction=left` is typed in full. An
ambiguous prefix runs nothing — `:ta n` could be `tab new` or `tab next`,
`:scr` could be `screen`, `screensaver`, `screenshot` or `scroll` — and the
completion list shows the candidates with no row highlighted; an unknown
word runs nothing either. The list highlights exactly what Enter would run,
so a row the arrows move to is what Enter runs instead. A topic runs bare
the one of its actions that just shows something: `:mappings`, `:logs`
(`logs show`, never `logs write`), `:about`, `flash logs`. One whose actions
all change something (`display sleep`, `screen lock`, `trash empty`) runs
nothing alone: type the action.

Abbreviations belong to what is typed: the command line and the `flash`
CLI. A config file and a mapping (`["flash", "ta", "nex"]`) reject them,
because an abbreviation written in a file would silently change meaning the
day a plugin adds a command that shares the prefix. A script is a file too:
spell its commands in full.

## Vim command-line aliases

Vim's ex commands are Flash commands under their vim names, typed at any
length from the bracketed minimum to the full name (`:q`, `:qu`, `:qui`,
`:quit`), case-sensitively (`:tabN` is not `:tabn`). An alias wins over a
prefix of a topic (`:h` is help, not `hints` or `history`), and an exact
Flash command wins over an alias that shares its first word (`:help show`).
Aliases take no further words, except where the table shows them:
`:h[elp] <topic>`, whose word is the help topic, itself completed by unique
prefix among the documentation's pages and the plugins' guides; a register
(`:y a`); a tab position (`:tabn 3`, `:b 3`) or offset (`:tabm +1`); a
`ctrl+w` window key (`:winc l`); or the keys of a NORMAL mapping
(`:norm 3gt`). `!` is read where vim reads it: `:qa!` and `:wqa!`
force-quit, `:e!` reverts the document to its last saved version (the
app's, after Flash asks), while `:q!`, `:w!` and `:wq!` run as without it,
since Flash holds no unsaved changes to discard. Aliases appear in completion with what
they run, and in the [command catalog](/commands).

| Alias | Runs |
| --- | --- |
| `q[uit]` | `app close`: the tab; in an app with no tab to close, the window, and the app with its last window |
| `qa[ll]`, `quita[ll]` | `app quit` (`!`: `--force`) |
| `bd[elete]` | `tab close` |
| `clo[se]` | `window close` |
| `w[rite]` | `app save` |
| `wq`, `x[it]`, `exi[t]` | `app save`, then `app close` when the save did not fail |
| `wqa[ll]`, `xa[ll]` | `app save_and_quit` (`!`: `--force`) |
| `tabnew`, `tabe[dit]` | `tab new` |
| `tabc[lose]` | `tab close` |
| `tabn[ext]` | `tab next` |
| `tabp[revious]`, `tabN[ext]` | `tab previous` |
| `tabfir[st]`, `tabr[ewind]` | `tab first` |
| `tabl[ast]` | `tab last` |
| `new`, `vne[w]` | `window new` |
| `sp[lit]` | `pane split_horizontal` |
| `vs[plit]` | `pane split_vertical` |
| `u[ndo]` | `app undo` |
| `red[o]` | `app redo` |
| `e[dit]` | `document open` (`!`: `document revert`, after asking) |
| `sav[eas]` | `document save_as` |
| `p[rint]`, `ha[rdcopy]` | `app print` |
| `opt[ions]` | `app settings` |
| `hid[e]` | `app hide` |
| `h[elp] [topic]` | `help show`, `--topic=<topic>` with a word |
| `map` | `mappings show` |
| `ter[minal]`, `sh[ell]` | `mode terminal` |
| `bn[ext]` | `tab next` |
| `bp[revious]`, `bN[ext]` | `tab previous` |
| `bf[irst]`, `br[ewind]` | `tab first` |
| `bl[ast]` | `tab last` |
| `b[uffer] N`, `tabn[ext] N` | `tab select --index=N` |
| `ls`, `buffers`, `files` | `window switch` |
| `tabm[ove] +N`, `tabm[ove] -N` | `tab move_next` / `tab move_previous`, N times |
| `winc[md] {c}` | the `ctrl+w {c}` window command (`h` `j` `k` `l` `w` `W` `q` `c` `n` `H` `J` `K` `L` `o` `=` `s` `v`) |
| `up[date]` | `app save` |
| `y[ank] [x]`, `pu[t] [x]` | `register yank` / `register paste`, into or from register `x` |
| `reg[isters]`, `di[splay]` | `clipboard show` (with words after it, `:disp` is the `display` topic: `:disp sleep`) |
| `so[urce]` | `config reload` |
| `ve[rsion]` | `about show` |
| `star[tinsert]`, `stopi[nsert]` | `mode insert` / `mode normal` |
| `mes[sages]` | `logs show` |
| `checkh[ealth]` | `resident doctor` |
| `norm[al] {keys}` | what typing those keys in NORMAL runs: counts, registers, marks, macros and `{N}gt` included |
| `{N}`, `$` | `cursor line --index=N` / `cursor last_line`: line N, the last line, of the field you engaged (`:42`, `:$`; `:0` is line 1) |
| `!{cmd}` | the shell command, its output shown |

The table is `commandLineSpecs` in `Sources/flash/App/NormalMode/CommandLineSpec.swift`;
a test keeps every name clear of Flash's topics, the bundled plugins'
commands and every other alias. An alias still wins over a topic it
prefixes: `:p` and `:pr` print, as vim's `:p[rint]`, so `process` is
`:proc` or longer. Two names are a topic's too: `h[elp]`, which runs
`help show` with its words as the topic, and Vim's `di[splay]`, the
registers, which leaves the words after it to the `display` topic. Beside
them, the grammar keeps one word of its own: `doctor` is `resident doctor`.
A topic alone runs the one of its actions that only shows a page or a
surface (`:logs` is `logs show`, never `logs write`; `:commands` is
`commands show`, `:media` is `media status`) or is a query; an action that
changes anything never runs implied, so `:screen` runs nothing where
`screen lock` would lock the screen, and `:display` is the registers, never
`display sleep`. A topic with one action still takes its arguments right
away (`:metrics --name=… --value=…`).

### `:normal` and `:!`

`:norm[al] {keys}` runs the NORMAL mapping its keys name in the focused app,
written as a mapping key is in `flash.toml`, after an optional register and
count: `:norm gt`, `:norm 3]t`, `:norm "ap`, `:norm ctrl+w H`, `:norm <leader>c`.
From a terminal, `flash normal 3gt` does the same, so a script can press any
mapping by its keys, plugin and per-app mappings included. Keys no mapping
takes exit 2.

`:!{cmd}` runs the rest of the line in your shell (`$SHELL -c`, Flash's login
environment) from the home directory, or from the shell's directory with
`flash '!{cmd}'`, and shows what it printed: one line on a banner, more in
the pager, or on the clipboard with `#` (`:#!git rev-parse HEAD`). A command
that fails exits 1 with its output.

### Macros, `.` and the configuration

`macro record --register=<x>`, `macro stop`, `macro play [--register=<x>]` and
`macro repeat [--count=<n>]` are vim's `q{x}`, `q`, `@{x}` / `@@` and `.`
([normal mode](normal-mode.md#repeat-and-macros)): they record and replay
the commands NORMAL ran and the command lines submitted, never keys, in the
running resident. An uppercase register appends (`qA`, `--register=A`), and
`macro play --register=:` is Vim's `@:`, the last command line again. `config reload`
(`:so`) reads the configuration file now; `config edit` opens it in its
default app, as the menu's Open Configuration does.

## Examples

```bash
flash mouse target                           # current-context click (terminal links add Shift)
flash mouse target --modifiers=cmd+shift     # new-context gesture for every target
flash mouse target --secondary               # right-click
flash mouse target --double                  # double-click
flash mouse target --middle                  # middle-click
flash mouse target --triple                  # triple-click
flash mouse target --move                    # move the pointer only
flash mouse target --drag                    # pick a grab point, then a drop point
flash mouse grid --drag                      # drag between two grid positions
flash mouse target --select                  # click a start point, shift-click an end point
flash mouse grid --select                    # select text between two grid positions
flash mouse target --multi                   # a click chain (NORMAL's alt+f): rediscovered after each click; Escape ends
flash mouse target --sticky                  # click several targets, the same labels stay up; Escape ends
flash mouse target --path                    # pick two targets, click every one between them in reading order
flash mouse target --copy-url                # label only links, copy the one you pick (Vimium's yf)
flash mouse target --copy-text               # label only what has text, copy the one you pick
flash mouse target --words                   # a label on every visible word, landing on its leading edge
flash mouse target --words --select          # highlight the text between two words
flash mouse repeat                           # re-click the last committed point
flash mouse target --adjust                  # refine the click point before committing
flash mouse target --search                  # type visible text to pick the target (seek & click)
flash mouse target --gesture=look_up         # Look Up the word at the target (smart_zoom: two-finger double tap there)
flash mouse bigram                           # type a visible character (v/V and 3/# match) in the window or status bar, then its hint bigram
flash mouse bigram --secondary               # right-click that letter
flash mouse bigram --double                  # double-click that letter
flash mouse bigram --move                    # move the pointer onto that letter
flash mouse target --scope=screen            # hints across every app on the screen
flash mouse dock                             # hint the Dock's items
flash mouse menubar                          # hint the focused app's menu titles and the status items
flash mouse notifications                    # hint Notification Center's banners, alerts and buttons
flash mouse pointer                          # freestyle cursor control (layout hjkl, m/,/. click, v drag)
flash mouse screens                          # each display shows its number; the pointer lands on the one you type
flash mouse screens --index=2 --focus        # display 2 at once (1 is the leftmost), focusing its frontmost window
flash mouse screens --direction=next --to=last # the next display, back where the pointer left it
flash mouse warp --area=window --edge=center # jump the pointer to a window or screen edge or centre
flash mouse step --direction=down            # move the pointer one text line (up, down) or character (left, right)
flash mouse position --action=save           # remember the pointer position (hints, next, previous, unsave, clear)
flash mouse position --action=hints --move   # label the saved positions and move to the one you pick
flash mode hold                              # grab what is under the pointer, or drop it (HOLD; --secondary, --middle)
flash mouse button --state=toggle --mode=hold # the same hold, spelled out
flash mouse button --state=release           # drop a drag, or end a selection, where the pointer is
flash mouse button --state=cancel            # put a drag back where it was grabbed
flash mouse nudge --direction=down --distance=16 # move the pointer (and a drag) a few points
flash mouse step --to=next_word              # jump to a word or line edge (previous_word, word_end, line_start, line_end)
flash selection copy                         # copy the selection, ending HOLD or VISUAL (paste pastes over it)
flash mouse gesture --fingers=3 --motion=swipe_up # a trackpad gesture: tap, double_tap, pinch, spread, rotate_*, swipe_*
flash app look_up                            # the focused app's Look Up on the word under the pointer
flash scroll target                          # pick which scroll area the scroll keys drive
# In the flashlight, "@menus print" finds and runs the frontmost app's menu items.
flash mouse grid                             # target any screen position (keyboard-shaped grid)
flash mouse grid --bisect                    # half at the layout's hjkl columns, quarter at y/u and b/n
flash mouse grid --zoom-to-depth=2           # start two steps deep under the pointer
flash mode insert                            # vim's i: type at the cursor; it takes no argument
flash mode visual --line                     # vim's V in the focused text: select the cursor's line (VISUAL)
flash input line_end                         # the cursor to its line's end, staying in NORMAL
flash cursor next_word                       # vim's w in the focused text: the caret to the next word's start
flash cursor line --index=10                 # vim's 10G: line 10's first non-blank (--percent=50: vim's 50%)
flash cursor till_next_char --char=,         # vim's t,: just before the next comma on the line
flash scroll cursor_middle                   # vim's zz: scroll the caret's line to the middle of its text
flash register paste --after                 # vim's p: one character on, then the app's paste
flash move half_page_down                    # ctrl+d: the caret or a list's selection 15 arrows down, else scroll
flash app open --name=Firefox                # open or focus an app
flash window move --position=lefthalf        # tile the focused window
flash window move --x=10% --y=10% --width=80% --height=80% # proportional frame
flash window minimize                        # minimize the focused window
flash window restore                         # restore the most recently minimized window
flash window fullscreen                      # toggle native macOS full screen
flash window fullscreen --state=on           # enter native full screen (off exits)
flash window focus --direction=right         # focus the nearest window to the right
flash window focus --direction=behind        # focus the window just behind the focused one (next, previous cycle the stack)
flash window next                            # the focused app's next window (window previous goes back)
flash window switch                          # every window, most recently used first: type its label (:ls)
flash window last                            # the window you were in before this one (ctrl+w p)
flash mark set --letter=a                    # save the focused app as mark a (a-z, 0-9)
flash mark jump --letter=a                   # bring that app back, or launch it
flash audio input                            # list input devices in Flash's message overlay
flash audio output --device='Studio Speakers' # select the default output device
flash volume down                            # one macOS volume step; the alert shows the percent (volume up, volume mute)
flash media status                           # what the running media apps play, and the volume
flash key system --key=brightness_down       # an Apple function-row key
flash key function --key=f1                  # plain F1, as shift+hyper+1 does
flash key arrow --direction=left             # one arrow; --shift holds Shift. HYPER uses the layout's ESDF positions
flash screen lock                            # lock the screen, as macOS's Control-Command-Q does
flash system sleep                           # sleep the Mac (display sleep turns only the displays off)
flash screensaver start                      # start the screen saver
flash appearance toggle                      # switch between light and dark appearance
flash missioncontrol show                    # open Mission Control; does nothing when it is open (hide, toggle)
flash desktop toggle                         # show the desktop, or bring the windows back
flash appwindows show                        # App Exposé: the focused app's windows
flash launchpad toggle                       # the Apps view on macOS 26, Launchpad before
flash notificationcenter show                # open Notification Center (controlcenter show opens Control Center)
flash system restart                         # asks first; y restarts (system shutdown, system logout, trash empty too)
flash process kill --pid=4242                # asks, then sends SIGTERM to one process
flash caffeinate toggle                      # keep the Mac awake, or let it sleep; #{flash.caffeinate} shows it
flash caffeinate on --minutes=30             # keep the Mac awake for 30 minutes (caffeinate off ends it early)
flash notes refresh                          # relist @notes now (reminders refresh, contacts refresh)
flash contacts open                          # open Contacts (notes open, reminders open)
flash calendar join                          # open the next or current event's meeting link, in its app
flash calendar next                          # print the next event: Standup in 12m · 09:30–09:45 · Zoom
flash clipboard show                         # open the clipboard history, the same words as :clipboard show
flash clipboard delete --id=<id>             # remove one history entry; <id> is 32 hex characters
flash clipboard pin --id=<id>                # keep an entry first and out of trimming (clipboard unpin undoes it)
flash clipboard restore --id=<id> --paste    # paste an entry into the focused app; --plain pastes its text only
flash alert confirm --prompt='Close it?' --command='tab close' # ask first: y runs the wrapped command, any other key closes the question
flash mode command                           # open the command line
flash mode terminal                          # show and focus the terminal popup; see docs/popups.md
flash mode terminal --name=btop              # show a [popup.<name>] centred and focused
flash mode layer --name=resize               # enter [mode.layers.resize]; Escape leaves it
flash mode leave                             # leave insert or a layer, or close the command panel or popup
flash help show                              # open the help homepage
flash help show --topic=flashlight           # open a feature guide
flash mappings show                          # open mappings for the focused app
flash plugins show                           # inspect plugins
flash monitors show                          # list monitors, their values and states
flash telemetry show                         # received OpenTelemetry data, receiver and exporter
flash about show                             # open the About Flash window
flash resident quit                          # stop the resident app
```

## Status, doctor, config, events and shell queries

Seven queries report instead of act. They run from a terminal or the command
line (`:resident status` shows the same text in the pager), they are not
commands a mapping can run, and their topics (`resident`, `config`,
`events`, `cli`) are Flash's, so no plugin command can take them. `flash config check` reads the
file the CLI's environment and directory name and needs no resident;
`:config check` checks the resident's file. `flash config schema` prints
`flash.toml`'s JSON Schema for this version, also without a resident, for
editors that validate and complete TOML ([configuration](configuration.md#editor-support)).
`flash cli completion --shell=zsh` (or `bash`, `fish`) and `flash cli manpage`
print the completion script and the `flash(1)` man page, generated from the
command table, so they list exactly what this version resolves.

```bash
flash resident status        # mode, key capture, input source, config, plugins, hint timings
flash resident status --json # the same as versioned JSON
flash resident doctor        # check permissions, capture, config, hotkeys, plugins
flash resident doctor --json
flash config check           # validate the active config file, offline
flash config check --file=~/dotfiles/flash.toml
flash config schema > ~/.config/flash/flash.schema.json
flash cli completion --shell=zsh > "${fpath[1]}/_flash"
flash cli manpage | mandoc -a
flash events watch                                   # every event, one JSON line each
flash events watch --name='core:mode.changed,core:hints.*'
flash events watch --name=core:config.changed --count=1   # wait for the next reload
```

`flash events watch` prints host events as they happen, one `event` JSON
object per line, flushed as each arrives: mode changes, the focused app and
window, configuration reloads, hint sessions shown, committed and cancelled,
monitors rising into warning or error, tiling workspaces, sleep, displays,
USB and the clock ([events](ipc-protocol.md#events)). `--name` takes event
names or globs, comma-separated (the default is `core:*`); `--count` exits 0
after that many. It runs until Flash quits (exit 1) or its reader goes away
(`| head -1`, exit 0); a reader that falls far behind is disconnected with a
message. It needs a terminal: the command line refuses it.

The Homebrew cask installs the completions for zsh, bash and fish and the
man page (`man flash`). Without it, load the completions from your shell's
startup file:

```bash
source <(flash cli completion --shell=bash)        # ~/.bashrc
flash cli completion --shell=fish | source          # ~/.config/fish/config.fish
```

In zsh, write the script to a directory on `$fpath` once, as above, before
`compinit` runs. Plugin commands (`flash <command> <subcommand>`) depend on
what is installed and are completed by the command line, not the scripts.

`flash resident status` asks the running resident. `--json` prints this object; the keys
are fixed for `"schema": 4`:

| Key | Value |
| --- | --- |
| `schema` | `4` |
| `version`, `build` | The app's version and build number |
| `mode` | `disabled`, `insert`, `normal`, `visual`, `hold`, `hyper`, `command`, `terminal`, or the name of the active [layer](layers.md) (`resize` for `[mode.layers.resize]`; no layer takes a built-in mode's name) |
| `mapping_scope` | The mapping table the mode reads and whose chords Flash registers: `insert`, `normal`, `text`, `visual`, `hold`, `command`, `terminal`, or the active layer's name. It follows `mode`, except that NORMAL reads `text` while a field is engaged ([Vim motions in text](normal-mode.md#vim-motions-in-text)) |
| `hint_session` | `idle`, `discovering`, `labels`, `grid`, `search`, `adjusting`, `pointer` or `bigram` |
| `focused_app` | The focused app's bundle identifier, or `null` |
| `frontmost_app` | The app macOS has frontmost, which receives every key Flash passes, or `null` |
| `flash_active` | Whether Flash itself is the active app. While it is, keys Flash passes reach Flash instead of the window that looks focused |
| `accessibility` | Whether Flash has the Accessibility grant |
| `capture` | How hint keys arrive: `tap`, or `key_window` without a tap or under secure input |
| `chord_routing` | What the keyboard tap does with a Command, Control or Option chord right now: `pass` (it reaches the app), `mapped_only` (INSERT: only chords a mapping claims are taken), `native_surface` (a menu, About, or Mission Control over NORMAL owns input: only mapped keys are taken), `swallowed` (NORMAL, a layer and hints take every chord) or `tap_off` (no live tap: only `global_chords` are taken) |
| `held_modifiers` | Modifiers the session's event state holds down: `cmd`, `ctrl`, `alt`, `shift`, `fn`, `caps_lock`. Empty unless a key is held, so an entry while nothing is pressed is a stuck key that rides every keystroke |
| `secure_input` | Whether secure input is on (a password field has focus, or an app left the hold on) |
| `global_chords` | The configured mapping keys Flash holds as system-wide hotkeys right now. Those chords never reach the focused app, so a native shortcut that stops working shows up here |
| `input_source` | The selected input source's ID |
| `keyboard_layout` | `[app] keyboard_layout` as configured |
| `reference_layout` | The layout keys are read on, or `null` while they read as typed |
| `config_path`, `config_diagnostics` | The config file and how many problems it has |
| `plugins` | `{ "loaded", "ready", "error" }` counts |
| `statusbar`, `autostart` | `[statusbar] enabled` and `[app] autostart` |
| `hints` | Recent target activations (`f` and its variants) per app, keyed by bundle identifier: `{ "count", "empty", "p50_ms", "p95_ms" }`. Each app keeps its last 50 activations, for the 32 most recently used apps; `empty` counts those whose app yielded no hints, and the nearest-rank percentiles (milliseconds from the trigger to the hints on screen) cover the others, or are `null` when none showed hints. Empty until hints are asked for; nothing is persisted |

The text rendering lists the three busiest apps under `hints`.

When a native shortcut stops reaching an app, run `flash resident status` while it
happens. `chord_routing`, `flash_active`, `frontmost_app`, `held_modifiers`
and `global_chords` together say whether Flash took the chord, sent it
elsewhere, or never saw it.

`flash resident doctor` (or `flash doctor`, `:doctor`) prints one line per check:
Accessibility, the keyboard tap, secure input (and which app holds it; a stuck
hold is released automatically, a focused password field is not), the
app's code signature (an ad-hoc signature can lose the Accessibility grant on
update), other Flash residents, config diagnostics, hotkeys another app
registered first, plugin health, hint and grid keys the current keyboard layout
cannot type, Screen Recording when the `screenshot` plugin runs, and, once
hints have been asked for, how recent activations went (`hint_activations`: a
warning names each app with at least 5 recent activations of which a fifth or
more showed no hints, or whose p95 exceeds 500 ms), and terminal popups whose
command is not on the login `PATH` (`popup_commands`, a warning naming each
popup). It exits 1 when a check fails; warnings do not change the exit code.

`flash config check` does not contact the resident. It loads the bundled
defaults and the file (`--file`, else the path Flash would load) exactly as the
resident does, prints each problem as `path:line:col: message`, and exits 1
when there is any, or 2 when the file cannot be read. Environment overrides are
not applied.

`mouse button --state=down|up|toggle|release|cancel [--mode=hold]`
starts a drag or text selection by holding a button where the pointer is, the primary one
unless `--secondary` or `--middle` says otherwise. `mode hold
[--secondary|--middle]` is the drag toggle by name: it grabs, or drops when
that button is already held; ⌘⌃H is the default toggle. `release` lets go of
whichever button is held, dropping a drag or ending a selection; `cancel`
first drags back to where the button went down. `mouse nudge
--direction=up|down|left|right [--distance=<points>]` moves the pointer,
16 points by default, dragging in HOLD.
While it is held, every pointer move Flash makes is a drag of that button:
`mouse target --move` (`mf`), `mouse grid --move` (`mF`), `mouse pointer`
movement and grid cursor-follow. So a keyboard drag in any app is `down`, a
move to the drop point, then `up`. One button is held at a time: pressing
another releases the first, and `up` for a button that is not held does
nothing. Cancelling a Flash overlay (Escape, or any other key that cancels
hints, the grid, `mouse pointer` or the command line), `mode leave` and
quitting Flash release it, and so does a committed click, drag or selection,
which presses buttons of its own.
`mouse pointer`'s `v` toggles the same hold.

`mouse target --scope=screen` also hints Picture in Picture players and the
Stage Manager strip on that screen. Flash picks them from WindowServer
geometry: every window of the system player (`com.apple.PIPAgent`), an app's
player-sized window at the floating level (a browser's own player), and the
thumbnail-sized windows of Stage Manager (`com.apple.WindowManager`). It then
walks each one through Accessibility by its frame. The Accessibility shapes of
these surfaces vary across macOS versions and have not been verified on every
release, so a player or strip that exposes nothing pressable stays silent.

`mouse grid` takes the click flags of `mouse target` except `--adjust`,
`--search`, `--path`, `--sticky`, `--copy-url` and `--copy-text`, plus `--bisect` and `--zoom-to-depth=N`
(N ≥ 1), which combine with every click flag.

`mouse target --path` picks two labels and clicks every target between them,
in reading order from the first pick to the second; `--sticky` keeps the same
labels up after each click with no new walk, where `--multi` discovers the
targets again, after each click and whenever the app reports a change before
the next pick. A chain ends on a Control-click or a click into the menu bar
(its menu keeps the keyboard), or another app coming forward; a click into
an input keeps it going, as no click enters INSERT. `--multi` and `--sticky`
take neither `--secondary` nor a `ctrl` modifier, since that click's menu
would end the chain at once ([click several targets](hints.md#click-several-targets)).
While Mission Control or App Exposé is up, every `mouse target` shape labels
its window thumbnails, desktops and add-desktop button instead of the
focused window ([Mission Control](hints.md#mission-control)). `--words` labels the visible words of the focused window's
text instead of its controls; it takes the click flags, `--move`, `--drag` and
`--select`, and the click lands on the word's leading edge. `--copy-url`
(Vimium's `yf`) labels only the targets that carry a URL, links mostly, and
copies the one you pick instead of clicking it; `--copy-text` labels the
targets with text (the label hint search matches) and copies that text. Each
takes no other flag, and nothing to copy stays silent. While labels are
up, `Tab` restarts the same click on the grid and `Shift-Tab` widens it to
every app on the screen (and back); `Backspace` with nothing typed returns to
the surface the session came from.

`mouse target`, `mouse bigram` and `mouse grid` take
`--gesture=look_up|smart_zoom` alone: the pointer lands on the pick as with
`--move`, then Flash runs that trackpad gesture there. In NORMAL a count
before a mouse finisher is a finger count, as on a trackpad: `2f` (or `2F`,
`2s`) secondary-clicks, `3f` looks up and `2df` smart-zooms at the pick.
Other counts change nothing.

`mouse gesture --fingers=2..5 --motion=<motion>` performs what that trackpad
gesture does under the default macOS trackpad settings, where the pointer is:

| Fingers | Motion | Effect |
|---------|--------|--------|
| 2 | `tap`, `double_tap` | secondary click, smart zoom |
| 2 | `pinch`, `spread`, `rotate_left`, `rotate_right` | zoom out, zoom in, rotate |
| 2 | `swipe_right`, `swipe_left` | back, forward (`history back`, `history forward`) |
| 3 | `tap` | Look Up (`app look_up`) |
| 3, 4 | `swipe_up`, `swipe_down` | Mission Control, App Exposé |
| 3, 4 | `swipe_left`, `swipe_right` | the Space to the right, to the left |
| 4, 5 | `pinch`, `spread` | Launchpad, show desktop |

Zoom, rotate and smart zoom post the same gesture events a trackpad does, so
an app that ignores a real trackpad's gesture ignores Flash's too. Look Up
and history are commands asked of the app; Spaces use the system shortcuts;
Mission Control, App Exposé, Launchpad and show desktop toggle as
`missioncontrol toggle`, `appwindows toggle`, `launchpad toggle` and
`desktop toggle` do ([system surfaces](#system-surfaces)).
A combination macOS gives no meaning to, such as a three-finger pinch, is a
config error.

`mouse screens` is monitor select: every display shows its number at its
centre, and typing one moves the pointer there; NORMAL's `gm` runs it with
`--focus`. See [pick a display](mouse-grid.md#pick-a-display). `mouse warp` moves the pointer to the centre or a side of the
focused window (`--area=window`, the default) or of its display
(`--area=screen`), a few points inside the edge. `mouse step` moves it one
text line up or down, in its column, or one character left or right,
measured from the glyph Accessibility reports under it; off text it moves a
fixed line height or column. `mouse step --to=next_word|previous_word|word_end|line_start|line_end`
jumps as Vim's `w`, `b`, `e`, `0` and `$` do. HOLD binds them to those keys.
`selection copy|paste` ends HOLD or [VISUAL](visual-mode.md) and copies
the selected text or pastes over it; neither enters INSERT. There is no
cut, delete or change: Flash never edits text
([what Flash does not do with text](vim.md#what-flash-does-not-do-with-text)).
`selection swap_ends` is VISUAL's `o`, which
moves the selection's other end; in HOLD it does nothing. `mouse position` keeps a
bounded list of saved pointer positions, per app with `[hints]
position_history_scope = "app"`: `save`, `unsave` the one under the pointer,
`clear`, `next` and `previous` cycle from the one the pointer is on, and
`hints` labels them, taking the click flags and `--move`. The screen splits like the left half of the keyboard; see
[normal mode](normal-mode.md#mouse-grid) for its keys.

`window move` accepts named positions (`topleft`, `topright`, `bottomleft`,
`bottomright`, `lefthalf`, `righthalf`, `tophalf`, `bottomhalf`, `maximized`,
or `centered`) or a complete proportional frame. Proportional frames require
`--x`, `--y`, `--width`, and `--height` together, each with a `%` suffix. `x`
and `y` are offsets from the top-left of Flash's usable screen area, including
its status-bar reservation on each display where the bar is configured to
render. Flash retains that geometry as window intent: an explicit
`--screen=+1` move, a resolution or usable-area change, and display
attachment/removal all reapply it against the destination screen. Every slot
lands on whole points, each edge rounded on its own, so neighbouring slots share
an edge. A display change that arrives while the Mac is locked or asleep (a wake
at a different desk) is applied once the session is back; a window whose frame
could not be read then is restored as soon as it can be, or when focused. A
window already sitting in a proportional frame one of your `window move`
mappings declares is recognized after Flash restarts.

`window minimize` acts on the focused window. `window restore` raises and
activates the most recent window minimized by Flash, including after focus
moves to another app. If none remains, it restores the first minimized window
of the focused app in Accessibility window order. `window fullscreen` toggles
native macOS full screen, or accepts `--state=on|off|toggle`; it needs a window
that exposes the Accessibility `AXFullScreen` attribute. All three run
Accessibility requests away from
Flash's keyboard input loop.

`window focus --direction=left|right|up|down` chooses the nearest cataloged
non-minimized window in that direction. `next` and `previous` cycle the
cataloged windows in WindowServer's stacking order, and `behind` focuses the
frontmost window below the focused one that it overlaps. `window switch`
lists every window of every app, most recently used first, minimized,
hidden and on other Spaces included, and focuses the one you pick; `:ls`
opens it from the command line. See [window navigation and placement](windows.md#switch-to-any-window)
for the switcher and for automatic placement rules. `flash audio input` and `flash audio output`
list or select the default device; see [audio devices](audio.md).

## System and processes

`screen lock`, `system sleep`, `display sleep`, `screensaver start` and
`appearance toggle` act at once. `system restart`, `system shutdown`,
`system logout`, `trash empty` and `process kill --pid=<pid>` cannot be
undone, so each asks first in the centred alert: `y` runs it, any other key
cancels. `screen lock` posts macOS's Lock Screen shortcut
(Control-Command-Q); `system sleep` and `display sleep` ask IOKit power
management directly; `screensaver start` opens ScreenSaverEngine. Restart,
shut down, log out and dark mode are scripted through System Events, and
emptying the Trash through Finder, off the keyboard path; the first use can
ask for Automation ([privacy](privacy.md)). `process kill` sends SIGTERM to a
process you may signal; it refuses pids 0 and 1 and a pid it cannot find.
In the flashlight, `@system` and `@processes` list
the same actions and every process ([flashlight](flashlight.md)).

`caffeinate on` keeps the Mac awake as `caffeinate -dimsu` does: the display,
idle and system sleep and the disk stay awake, and a sleeping display wakes.
`--minutes=N` bounds the hold; `caffeinate toggle` accepts the same bound, and
`caffeinate off` ends it early. The hold belongs to the resident, so
`flash resident quit` ends it too. Each of these commands shows a
`caffeinate on` or `caffeinate off` alert and prints the same words in a
terminal; `flash caffeinate status` only prints them, and shows the alert
when a mapping runs it. `#{flash.caffeinate}` is `on` in a status format
while the hold lasts.

## System surfaces

`desktop`, `missioncontrol`, `appwindows`, `launchpad`,
`notificationcenter` and `controlcenter` each take `show`, `hide` and
`toggle`. `show` does nothing when the surface already shows and `hide`
nothing when it does not, so a script or a mapping asks for the state it
wants; `toggle` is whichever of the two applies. Hyper+3 is `missioncontrol toggle`, and the
[`mouse gesture`](#command-reference) swipes and pinches for these surfaces
toggle them the same way. None of them changes Flash's mode.

| Topic | Surface | Opened by | Known to show by |
| --- | --- | --- | --- |
| `desktop` | Show Desktop | A Dock request | The Dock's report |
| `missioncontrol` | Mission Control | A Dock request | The Dock's report |
| `appwindows` | App Exposé, the focused app's windows | A Dock request | The Dock's report |
| `launchpad` | The Apps view on macOS 26, Launchpad before | A Dock request | Spotlight's panel on macOS 26; nothing before |
| `notificationcenter` | Notification Center | A press of the menu-bar clock | Its panel |
| `controlcenter` | Control Center | A press of its menu-bar item | Its panel |

Show Desktop, Mission Control and App Exposé are the Dock's views. Flash asks
the Dock to toggle one through `CoreDockSendNotification`, a private Dock
entry point resolved at run time, and learns which view shows from the
notifications the Dock posts to Accessibility as each opens and closes,
which Flash observes from launch. A Dock request made
while a view shows returns to the windows instead of switching views, so
`missioncontrol show` over Show Desktop first leaves Show Desktop, waits for
the Dock to report it gone, then opens Mission Control. Commands run one at
a time, each after the Dock confirmed the last, so a burst of
`missioncontrol toggle` opens and closes in turn. A `show` or `hide` the
Dock does not confirm within 1.5 s fails, and the CLI exits 1 saying so; an
unconfirmed `toggle` still counts as run. Without Accessibility, while the
Dock restarts, or after it left a request unconfirmed and until it reports
again, Flash does not know the Dock's view: `toggle` still asks the Dock,
and `show` and `hide` fail.

`launchpad` toggles through the Dock request of the same name. On macOS 26
the Apps view that replaced Launchpad is Spotlight's panel, and an open
Spotlight search is the same panel to Accessibility, so `launchpad show`
counts an open Spotlight search as shown and `launchpad hide` asks the Dock
to close it. Before macOS 26 nothing reports whether Launchpad is open:
`launchpad toggle` works, and `launchpad show` and `launchpad hide` fail.
`launchpad show` over a Dock view leaves the view first.

`notificationcenter` and `controlcenter` press the menu bar's clock and its
Control Center item through Accessibility, as a click there does. A panel
counts as open while its process (`com.apple.notificationcenterui`,
`com.apple.controlcenter`) shows a system-dialog window. A press waits until its panel
shows or closes (about a second at most) before the next command plans, and
commands for the same panel queued meanwhile fold into their net effect: two
toggles cancel out, and a `show` or `hide` decides. A burst of
`notificationcenter toggle` ends as its count says, pressing only as often
as the panel can follow.

## Startup commands

`startup run` runs [`[startup] run`](startup.md) again, as each launch
does: every command in order, the next one even after a failure, each
bounded by `[startup] timeout`. It prints a line per command, `ok` or
`failed` with the reason and the end of its output, and fails when one
failed; from a mapping, a banner shows the summary. A run still going
refuses a second one. Saving the configuration never runs the list.

## Updates

`updates check` asks GitHub for the newest release and prints what
installing it means for the running build; with `[app] updates = "install"`
the download and its verification follow in the background. `updates install` installs the newest
release and restarts Flash into it, and fails with the reason when this
build cannot be replaced (a development build, a bundle your user cannot
write). The topic is plural because `:up[date]` is vim's save. See
[updates](updates.md).

## Notes, Reminders and Contacts

`notes refresh`, `reminders refresh` and `contacts refresh` relist the
flashlight's `@notes`, `@reminders` or `@contacts` now and
say so in a banner; the lists are otherwise kept fresh by events
([flashlight](flashlight.md)). A refresh while the app is not running
empties its list. The first one, like the first search, asks macOS for
access (Automation of Notes, Reminders, Contacts); a refusal leaves the list
empty without a banner. `notes open`, `reminders open` and `contacts open`
open the app.

## Calendar

`calendar join` opens the meeting link of the event about to start or just
started, else of the meeting in progress, else of the next event: Zoom,
Google Meet, Microsoft Teams, Webex, Around, Whereby, FaceTime, Slack huddles
and other links found in the event's URL, location or notes. A Zoom or Teams
link opens in its app when it is installed. `calendar next` shows the next
event in the centred alert, or prints it from the CLI. With no event in the
look-ahead, an event without a link for `calendar join`, or no access to your
calendars, either exits 1 and says why. The first one asks macOS for
Calendars access if Flash never asked. See [calendar](calendar.md#next-meeting)
for which event is next and the `#{flash.calendar.next}` values.

## Notifications, logs and metrics

Three commands let a script, a mapping or the command line reach past
Flash's own surfaces; each takes its words alike from the CLI and from `:`.

`notify send` posts a native macOS notification. Unlike `alert show`, which
draws Flash's centred alert and lets it go, a notification stays in
Notification Center until dismissed:

```sh
flash notify send --title="Build done" --body="All tests passed" --sound --id=build
flash notify send --title="Deploy failed" --url=https://ci.example.com/run/42
flash notify send --title="Standup" --command="app open --name=Zoom"
flash notify clear --id=build
```

`--title` or `--body` is required; `--subtitle` and `--sound` are optional. A
click opens `--url` (any scheme but `file:`, `data:` and `javascript:`) or
runs `--command`, a Flash command as a mapping names it, never both. A
notification posted with the same `--id` replaces the earlier one;
`notify clear` removes one by `--id`, or all of Flash's. The first
notification asks macOS for permission; until then nothing is asked, and
once refused, `notify send` exits 1 saying where to allow it (System
Settings › Notifications › Flash). Monitors post them too with
[`notify = true`](monitors.md#keys).

`logs write` writes one line to Flash's log through the same writer as
Flash's own lines. A level flag picks the level (`--trace`, `--debug`,
`--info`, `--warn` or `--error`; info without one), `--area` tags it (a
snake_case word, `user` by default) and `--fields` adds `key=value` pairs.
It shares its topic with `logs show`, so it is typed in full:

```sh
flash logs write --warn --message="disk almost full" --area=backup --fields=job=nightly
```

The line reads `[backup] disk almost full` with `job` as a field and `user` as
its source, so the [logs page](help.md) and `docs/observability.md`'s
filters tell it apart from Flash's and plugins' lines. `[debug] log_level`
drops a line below it, as it drops Flash's.

`metrics record` records one measurement into Flash's metrics, where
`#{flash.otel:<metric>}` and [monitors](monitors.md) read it and the
[exporter](telemetry.md#the-exporter) sends it with Flash's own:

```sh
flash metrics record --name=build.duration --value=42.5 --kind=histogram --unit=s --attributes=job=ci
```

See [recording metrics](telemetry.md#recording-metrics) for the kinds, the
naming rule and an end-to-end example.

## Pushed status values

`status set --name=<source> --value=<text>` puts a value into a declared
`[statusbar.sources.<name>]` the moment something happens, instead of on its
next poll; `status clear --name=<source>` empties it. A source declared
without a `command` is only ever pushed: it runs nothing and starts empty
after a restart. One with a command keeps polling, and a push lands between
its runs. Either way the value is taken as a run's output would be: a
number joins `history`, `cycle_interval` rotates its lines, and every bar,
widget and monitor reading the source updates at once. A push to a source no
table declares exits 1 and names the table to add.

The source is how tiling window managers drive the bar without polling. With
AeroSpace, run the command from `exec-on-workspace-change` in
`~/.aerospace.toml`:

```toml
exec-on-workspace-change = ['/bin/bash', '-c',
  'flash status set --name=workspace --value="$AEROSPACE_FOCUSED_WORKSPACE"'
]
```

and show it in Flash's bar:

```toml
[statusbar.sources.workspace]

[statusbar]
template = "#[align=left]#[pill] #{flash.source.workspace} #[nopill]#[align=right]%H:%M"
```

yabai's `space_changed` signal does the same
(`yabai -m signal --add event=space_changed action="flash status set --name=workspace --value=$(yabai -m query --spaces --space | jq .index)"`),
and so does any script, cron job or hook that can run `flash`.

`status refresh --name=<source>` asks the other way round: it runs a source's
own command now instead of at its next `interval`, as an i3blocks signal
(`pkill -RTMIN+1 i3blocks`), a waybar `signal` or a SketchyBar `--trigger`
does. A volume key script can poll nothing and refresh the volume source
after each change:

```sh
osascript -e 'set volume output volume 50' && flash status refresh --name=volume
```

A run already in flight is followed by one more the moment it ends, so the
value shown is never older than the request. Only a source the bar or a
widget shows runs; refreshing one nothing shows, one without a command or a
name no table declares exits 1 and says which.

## Marks

`mark set --letter=a` saves the focused app under `a`; any ASCII letter or
digit is a slot, 36 in all. `mark jump --letter=a` brings it back: the saved
process while it still runs, else another running copy of the app, else a
fresh launch. Marks have no default keys and persist across restarts; see
[marks](marks.md) for mappings and where they are stored.
