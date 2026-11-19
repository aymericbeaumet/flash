import AppKit
import FlashCore

/// The resident itself: its pages, plugins, logs, configuration and updates.
extension URLEventHandler {
  static let flashCommands: [String: CommandDefinition] = [
    "help show": .init(
      "Open Flash's help, or a documentation page with --topic", [.text("topic", "topic")],
      parse: { a in .showUsage(topic: a.value("topic")) }),
    "mappings show": .init(
      "Open the mappings page for the focused app", parse: { _ in .showMappings }),
    "plugins show": .init(
      "Open the plugins page", parse: { _ in .showPlugins }),
    "plugins reload": .init(
      "Stop and restart every loaded plugin", parse: { _ in .reloadPlugins }),
    "logs show": .init(
      "Open the logs page", parse: { _ in .showLogs }),
    "logs write": .init(
      "Write a line to Flash's log, at info or the level flag given",
      [
        .text("message", "text", required: true), .flag("trace"), .flag("debug"), .flag("info"),
        .flag("warn"), .flag("error"), .text("area", "area"), .text("fields", "key=value,..."),
      ],
      parse: { a in
        let levels = LogWrite.levels.filter { a.bool($0.name) }
        guard
          case .success(let write) = LogWrite.make(
            levelFlags: levels, message: a.value("message"), area: a.value("area"),
            fields: a.value("fields"))
        else { return nil }
        return .logWrite(write)
      }),
    "metrics record": .init(
      "Record a gauge, counter or histogram value into Flash's metrics",
      [
        .text("name", "metric", required: true), .text("value", "number", required: true),
        .text("kind", "gauge|counter|histogram"), .text("unit", "unit"),
        .text("attributes", "key=value,..."),
      ],
      parse: { a in
        guard let name = a.value("name"), let value = a.value("value"),
          case .success(let record) = MetricRecord.make(
            name: name, value: value, kind: a.value("kind"), unit: a.value("unit"),
            attributes: a.value("attributes"))
        else { return nil }
        return .metricRecord(record)
      }),
    "notify send": .init(
      "Post a macOS notification; a click can open --url or run --command",
      [
        .text("title", "text"), .text("subtitle", "text"), .text("body", "text"),
        .flag("sound"), .text("url", "url"), .text("command", "topic action [--arg=value ...]"),
        .text("id", "id"),
      ],
      parse: { a in
        guard
          case .success(let request) = NotifyRequest.make(
            title: a.value("title"), subtitle: a.value("subtitle"), body: a.value("body"),
            sound: a.bool("sound"), url: a.value("url"), command: a.value("command"),
            id: a.value("id"))
        else { return nil }
        return .notify(.send(request))
      }),
    "notify clear": .init(
      "Remove Flash's notifications from Notification Center, or the one --id names",
      [.text("id", "id")],
      parse: { a in
        if let id = a.value("id") {
          return NotifyRequest.isValidID(id) ? .notify(.clear(id: id)) : nil
        }
        return .notify(.clear(id: nil))
      }),
    "commands show": .init(
      "Open the command catalog", parse: { _ in .showCommands }),
    "monitors show": .init(
      "Open the monitors page", parse: { a in a.args.isEmpty ? .showMonitors : nil }),
    "telemetry show": .init(
      "Open the telemetry page", parse: { a in a.args.isEmpty ? .showTelemetry : nil }),
    "about show": .init(
      "Open the About Flash window", parse: { _ in .showAbout }),
    "resident quit": .init(
      "Quit Flash", parse: { _ in .quit }),
    "config reload": .init(
      "Re-read the configuration file now", parse: { _ in .configReload }),
    "config edit": .init(
      "Open the configuration file in its default app", parse: { _ in .configEdit }),
    "updates check": .init(
      UpdatesCommand.check.summary, parse: { a in a.args.isEmpty ? .updates(.check) : nil }),
    "updates install": .init(
      UpdatesCommand.install.summary, parse: { a in a.args.isEmpty ? .updates(.install) : nil }),
    "startup run": .init(
      StartupCommand.run.summary, parse: { a in a.args.isEmpty ? .startup(.run) : nil }),
  ]
}
