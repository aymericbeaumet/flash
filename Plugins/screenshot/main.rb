#!/usr/bin/env ruby
# Native screenshot shortcuts, in Ruby (one of the six deliberately
# non-Rust official plugins exercising the language-agnostic wire protocol;
# see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
#
# Synthesizes the macOS screenshot keystrokes via System Events, exactly
# like the Rust implementation: cmd+shift+3/4/5 (key codes 20/21/23), the
# control variants copy to the clipboard, and the window flavors follow
# cmd+shift+4 with Space to enter the window picker.

require_relative "flashplugin"

SETTLE_DELAY_SECONDS = "0.20"
WINDOW_PICKER_DELAY_SECONDS = "0.12"

# subcommand => [key_code, control, then_space]
SHORTCUTS = {
  "" => [23, false, false],
  "options" => [23, false, false],
  "screen" => [20, false, false],
  "selection" => [21, false, false],
  "window" => [21, false, true],
  "screen_clipboard" => [20, true, false],
  "selection_clipboard" => [21, true, false],
  "window_clipboard" => [21, true, true],
}.freeze

def script_for(key_code, control, then_space)
  modifiers = control ? "command down, control down, shift down" : "command down, shift down"
  script = +"delay #{SETTLE_DELAY_SECONDS}\n"
  script << "tell application \"System Events\" to key code #{key_code} using {#{modifiers}}"
  if then_space
    script << "\ndelay #{WINDOW_PICKER_DELAY_SECONDS}\n"
    script << "tell application \"System Events\" to key code 49"
  end
  script
end

plugin = FlashPlugin.new
plugin.serve do |params|
  shortcut = SHORTCUTS[params["subcommand"].to_s]
  if shortcut.nil?
    { "ok" => false, "error" => "unknown subcommand: #{params["subcommand"]}" }
  else
    out = IO.popen(["/usr/bin/osascript", "-e", script_for(*shortcut)], err: %i[child out], &:read)
    status = $?
    if status.success?
      { "ok" => true }
    else
      { "ok" => false, "error" => out.to_s.strip }
    end
  end
end
