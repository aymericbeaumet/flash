import FlashCore
import Foundation
import TOMLKit

/// `[telemetry]`: the receiver and the exporter.
extension ConfigLoader {
  static let telemetryReceiverKeys: Set<String> = [
    "enabled", "port", "max_series", "max_points", "max_logs", "max_spans", "token",
  ]
  static let telemetryExporterKeys: Set<String> = [
    "endpoint", "protocol", "compression", "headers", "service_name", "signals", "interval",
  ]

  /// Headers Flash sets itself; a configured one would contradict the body.
  static let reservedTelemetryHeaders: Set<String> = [
    "content-type", "content-length", "content-encoding", "transfer-encoding", "host",
    "connection", "user-agent",
  ]

  /// `[telemetry.receiver]` and `[telemetry.exporter]`. Each key validates
  /// alone, in every layer; checks across keys and layers run once all
  /// layers are applied (`diagnoseTelemetry`).
  static func applyTelemetry(
    _ table: TOMLTable?, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    guard let table else { return }
    warnUnknownKeys(
      in: table, known: ["receiver", "exporter"], path: ["telemetry"], locations: locations,
      into: &config)
    if let value = table["receiver"] {
      if let receiver = value.table {
        applyTelemetryReceiver(receiver, locations: locations, into: &config)
      } else {
        config.addDiagnostic(
          "telemetry.receiver must be a table ([telemetry.receiver] on its own line)",
          location: locations.location(for: ["telemetry", "receiver"]))
      }
    }
    if let value = table["exporter"] {
      if let exporter = value.table {
        applyTelemetryExporter(exporter, locations: locations, into: &config)
      } else {
        config.addDiagnostic(
          "telemetry.exporter must be a table ([telemetry.exporter] on its own line)",
          location: locations.location(for: ["telemetry", "exporter"]))
      }
    }
  }

  private static func applyTelemetryReceiver(
    _ table: TOMLTable, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    let path = ["telemetry", "receiver"]
    warnUnknownKeys(
      in: table, known: telemetryReceiverKeys, path: path, locations: locations, into: &config)
    applyBool(
      table["enabled"], path: path + ["enabled"],
      message: "telemetry.receiver.enabled must be true or false", locations: locations,
      into: &config
    ) { value, config in config.telemetry.receiver.enabled = value }
    applyInt(
      table["port"], path: path + ["port"],
      message: "telemetry.receiver.port must be an integer in 1..65535", locations: locations,
      into: &config, validate: { (1...65535).contains($0) },
      assign: { value, config in config.telemetry.receiver.port = value })
    applyString(
      table["token"], path: path + ["token"],
      message:
        "telemetry.receiver.token must be printable text of at most 1024 bytes, without spaces",
      locations: locations, into: &config,
      validate: { token in
        token.utf8.count <= 1024
          && !token.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
              || CharacterSet.controlCharacters.contains($0)
          }
      },
      assign: { value, config in config.telemetry.receiver.token = value })
    let bounds: [(String, ClosedRange<Int>, WritableKeyPath<Config.Telemetry.Receiver, Int>)] = [
      ("max_series", 1...10_000, \.maxSeries),
      ("max_points", 2...1000, \.maxPoints),
      ("max_logs", 0...100_000, \.maxLogs),
      ("max_spans", 0...100_000, \.maxSpans),
    ]
    for (key, range, keyPath) in bounds {
      applyInt(
        table[key], path: path + [key],
        message:
          "telemetry.receiver.\(key) must be an integer in \(range.lowerBound)..\(range.upperBound)",
        locations: locations, into: &config, validate: { range.contains($0) },
        assign: { value, config in config.telemetry.receiver[keyPath: keyPath] = value })
    }
  }

  private static func applyTelemetryExporter(
    _ table: TOMLTable, locations: ConfigSourceLocationIndex, into config: inout Config
  ) {
    let path = ["telemetry", "exporter"]
    warnUnknownKeys(
      in: table, known: telemetryExporterKeys, path: path, locations: locations, into: &config)
    applyString(
      table["endpoint"], path: path + ["endpoint"],
      message:
        "telemetry.exporter.endpoint must be empty or an http(s) URL with a host and no "
        + "credentials, query or fragment",
      locations: locations, into: &config, validate: { $0.isEmpty || isValidExportEndpoint($0) },
      assign: { value, config in config.telemetry.exporter.endpoint = value })
    applyString(
      table["protocol"], path: path + ["protocol"],
      message: "telemetry.exporter.protocol must be \"http/protobuf\" or \"http/json\"",
      locations: locations, into: &config, validate: { OTLPEncoding(rawValue: $0) != nil },
      assign: { value, config in
        config.telemetry.exporter.encoding = OTLPEncoding(rawValue: value) ?? .protobuf
      })
    applyString(
      table["compression"], path: path + ["compression"],
      message: "telemetry.exporter.compression must be \"none\" or \"gzip\"",
      locations: locations, into: &config, validate: { ["none", "gzip"].contains($0) },
      assign: { value, config in config.telemetry.exporter.gzip = value == "gzip" })
    if let value = table["headers"] {
      let location = locations.location(for: path + ["headers"])
      if let headers = stringTableValue(value),
        headers.allSatisfy({ isValidHeaderName($0.key) && isValidHeaderValue($0.value) }),
        headers.keys.allSatisfy({ !reservedTelemetryHeaders.contains($0.lowercased()) })
      {
        config.telemetry.exporter.headers = headers
        config.recordLocation(path: "telemetry.exporter.headers", location: location)
      } else {
        config.addDiagnostic(
          "telemetry.exporter.headers must be a table of header names to string values "
            + "(no line breaks, and not \(reservedTelemetryHeaders.sorted().joined(separator: ", ")))",
          location: location)
      }
    }
    applyString(
      table["service_name"], path: path + ["service_name"],
      message: "telemetry.exporter.service_name must be a non-empty string of at most 255 bytes",
      locations: locations, into: &config,
      validate: { !$0.isEmpty && $0.utf8.count <= 255 },
      assign: { value, config in config.telemetry.exporter.serviceName = value })
    if let value = table["signals"] {
      let location = locations.location(for: path + ["signals"])
      let names = stringArrayValue(value) ?? ["?"]
      let signals = names.compactMap(TelemetrySignal.init(rawValue:))
      if signals.count == names.count, Set(signals).count == signals.count {
        config.telemetry.exporter.signals = Set(signals)
        config.recordLocation(path: "telemetry.exporter.signals", location: location)
      } else {
        config.addDiagnostic(
          "telemetry.exporter.signals must be an array naming each of \"metrics\", \"logs\" "
            + "and \"traces\" at most once",
          location: location)
      }
    }
    applyInt(
      table["interval"], path: path + ["interval"],
      message: "telemetry.exporter.interval must be an integer between 1 and 3600 (seconds)",
      locations: locations, into: &config, validate: { (1...3600).contains($0) },
      assign: { value, config in config.telemetry.exporter.intervalSeconds = value })
  }

  /// An http(s) URL with a host and nothing that could carry a secret the
  /// help page would show: no user, password, query or fragment.
  static func isValidExportEndpoint(_ raw: String) -> Bool {
    guard let components = URLParsing.components(raw),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil, components.query == nil,
      components.fragment == nil
    else { return false }
    return true
  }

  /// An RFC 9110 token.
  static func isValidHeaderName(_ name: String) -> Bool {
    !name.isEmpty
      && name.unicodeScalars.allSatisfy {
        $0.isASCII
          && (CharacterSet.alphanumerics.contains($0)
            || "!#$%&'*+-.^_`|~".unicodeScalars.contains($0))
      }
  }

  static func isValidHeaderValue(_ value: String) -> Bool {
    value.utf8.count <= 4096
      && !value.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" }
  }

  /// After every layer: an exporter aimed at Flash's own receiver, an empty
  /// signal list, and a receiver port taken by the help server.
  static func diagnoseTelemetry(into config: inout Config) {
    let telemetry = config.telemetry
    let locations = config.valueLocations
    if !telemetry.exporter.endpoint.isEmpty, let url = URLParsing.url(telemetry.exporter.endpoint),
      Config.Telemetry.targetsReceiver(url, receiver: telemetry.receiver)
    {
      config.addDiagnostic(
        "telemetry.exporter.endpoint is Flash's own receiver; the exporter stays off rather "
          + "than feed Flash's telemetry back into itself",
        location: locations["telemetry.exporter.endpoint"])
    }
    if !telemetry.exporter.endpoint.isEmpty, telemetry.exporter.signals.isEmpty {
      config.addDiagnostic(
        "telemetry.exporter.signals is empty, so the exporter has nothing to send",
        location: locations["telemetry.exporter.signals"])
    }
    if telemetry.receiver.enabled, telemetry.receiver.port == config.debug.httpInspectorPort {
      config.addDiagnostic(
        "telemetry.receiver.port \(telemetry.receiver.port) is the help server's "
          + "debug.http_inspector_port; pick another",
        location: locations["telemetry.receiver.port"])
    }
  }
}
