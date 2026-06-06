import AppKit
import Foundation

private let usage = """
Usage:
  flash <action> [query...]
  flashctl <action> [query...]

Examples:
  flash mouse_target
  flash mouse_target double=1
  flash mouse_snipe move=1
  flash mode_normal
  flash app_open name=Firefox
  flash window_move position=lefthalf
  flash flash://help_show
"""

private func percentEncode(_ value: String) -> String {
  value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private func buildURLString(from args: [String]) -> String? {
  guard let first = args.first else { return nil }
  if first == "-h" || first == "--help" {
    print(usage)
    exit(0)
  }
  if first.hasPrefix("flash://") {
    return args.count == 1 ? first : nil
  }

  let command = first.replacingOccurrences(of: "-", with: "_")
  let rest = Array(args.dropFirst())
  if rest.isEmpty {
    return "flash://\(command)"
  }
  if command == "app_open", rest.count == 1, !rest[0].contains("=") {
    return "flash://\(command)?name=\(percentEncode(rest[0]))"
  }
  if command == "alert_show", !rest.contains(where: { $0.contains("=") }) {
    return "flash://\(command)?message=\(percentEncode(rest.joined(separator: " ")))"
  }
  let query = rest.map { part -> String in
    guard let eq = part.firstIndex(of: "=") else { return percentEncode(part) }
    let key = String(part[..<eq])
    let value = String(part[part.index(after: eq)...])
    return "\(key)=\(percentEncode(value))"
  }.joined(separator: "&")
  return "flash://\(command)?\(query)"
}

let args = Array(CommandLine.arguments.dropFirst())
guard let rawURL = buildURLString(from: args), let url = URL(string: rawURL) else {
  FileHandle.standardError.write((usage + "\n").data(using: .utf8)!)
  exit(2)
}

if NSWorkspace.shared.open(url) {
  exit(0)
}

FileHandle.standardError.write("flash: could not dispatch \(rawURL)\n".data(using: .utf8)!)
exit(1)
