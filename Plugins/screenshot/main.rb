#!/usr/bin/env ruby
# Native screenshot shortcuts, in Ruby (one of the six deliberately
# non-Rust official plugins exercising the language-agnostic wire protocol;
# see docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
#
# Synthesizes the macOS screenshot keystrokes via System Events, exactly
# like the Rust implementation: cmd+shift+3/4/5 (key codes 20/21/23), the
# control variants copy to the clipboard, and the window flavors follow
# cmd+shift+4 with Space to enter the window picker. Commands arrive as
# perform kind "command", routed to the on_command hook.

require "flashplugin" # resolved via host-injected RUBYLIB

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

FlashPlugin.new.serve(
  on_command: lambda do |params|
    shortcut = SHORTCUTS[params["subcommand"].to_s]
    if shortcut.nil?
      FlashPlugin.fail("unknown subcommand: #{params["subcommand"]}")
    else
      out = IO.popen(["/usr/bin/osascript", "-e", script_for(*shortcut)], err: %i[child out], &:read)
      if $?.success?
        FlashPlugin.ok
      else
        message = out.to_s.strip
        FlashPlugin.fail(message.empty? ? "osascript failed" : message)
      end
    end
  end,
)
