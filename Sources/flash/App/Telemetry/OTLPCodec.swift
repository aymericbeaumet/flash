import FlashOTLP
import Foundation
import SwiftProtobuf
import zlib

typealias OTLPMetricsRequest = Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest
typealias OTLPMetricsResponse =
  Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceResponse
typealias OTLPLogsRequest = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest
typealias OTLPLogsResponse = Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse
typealias OTLPTraceRequest = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest
typealias OTLPTraceResponse = Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse
typealias OTLPAnyValue = Opentelemetry_Proto_Common_V1_AnyValue
typealias OTLPKeyValue = Opentelemetry_Proto_Common_V1_KeyValue

/// The three OTLP signals.
enum TelemetrySignal: String, CaseIterable, Hashable, Comparable {
  case metrics
  case logs
  case traces

  /// The OTLP/HTTP path a signal is posted to.
  var path: String { "/v1/\(rawValue)" }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// OTLP/HTTP's two encodings.
enum OTLPEncoding: String, CaseIterable, Equatable {
  case protobuf = "http/protobuf"
  case json = "http/json"

  var contentType: String {
    switch self {
    case .protobuf: return "application/x-protobuf"
    case .json: return "application/json"
    }
  }

  /// The encoding a request's `Content-Type` names; parameters such as
  /// `charset` are ignored.
  init?(contentType: String) {
    let media = contentType.split(separator: ";").first.map {
      $0.trimmingCharacters(in: .whitespaces).lowercased()
    }
    switch media {
    case "application/x-protobuf": self = .protobuf
    case "application/json": self = .json
    default: return nil
    }
  }
}

/// A decoded export request of any signal.
enum OTLPExport {
  case metrics(OTLPMetricsRequest)
  case logs(OTLPLogsRequest)
  case traces(OTLPTraceRequest)
}

enum OTLPCodecError: Error, Equatable {
  case malformed(String)
  case tooLarge
}

/// OTLP/HTTP bodies in both encodings. OTLP/JSON is the proto3 JSON mapping
/// with two departures: trace and span ids are hex rather than base64, and
/// enums are integers. Decoding rewrites the ids before SwiftProtobuf reads
/// the document and ignores unknown fields, as the specification requires of
/// a receiver; encoding writes integer enums and rewrites the ids back.
enum OTLPCodec {
  /// The id fields OTLP/JSON writes as hex: spans, links, log records and
  /// exemplars.
  static let idKeys: Set<String> = [
    "traceId", "spanId", "parentSpanId", "trace_id", "span_id", "parent_span_id",
  ]

  static func decode(
    _ body: Data, signal: TelemetrySignal, encoding: OTLPEncoding
  ) throws -> OTLPExport {
    switch encoding {
    case .protobuf:
      do {
        switch signal {
        case .metrics: return .metrics(try OTLPMetricsRequest(serializedBytes: body))
        case .logs: return .logs(try OTLPLogsRequest(serializedBytes: body))
        case .traces: return .traces(try OTLPTraceRequest(serializedBytes: body))
        }
      } catch {
        throw OTLPCodecError.malformed("invalid protobuf \(signal.rawValue) request")
      }
    case .json:
      let rewritten = try rewriteIDs(in: body, toBase64: true)
      var options = JSONDecodingOptions()
      options.ignoreUnknownFields = true
      do {
        switch signal {
        case .metrics:
          return .metrics(try OTLPMetricsRequest(jsonUTF8Data: rewritten, options: options))
        case .logs:
          return .logs(try OTLPLogsRequest(jsonUTF8Data: rewritten, options: options))
        case .traces:
          return .traces(try OTLPTraceRequest(jsonUTF8Data: rewritten, options: options))
        }
      } catch {
        throw OTLPCodecError.malformed("invalid JSON \(signal.rawValue) request")
      }
    }
  }

  static func encode(_ message: some SwiftProtobuf.Message, as encoding: OTLPEncoding) throws
    -> Data
  {
    switch encoding {
    case .protobuf:
      return try message.serializedData()
    case .json:
      var options = JSONEncodingOptions()
      options.alwaysPrintEnumsAsInts = true
      let data = try message.jsonUTF8Data(options: options)
      return try rewriteIDs(in: data, toBase64: false)
    }
  }

  /// Rewrite every id field of a JSON document between OTLP's hex and the
  /// proto3 mapping's base64. A value that is not a valid id in the source
  /// form is left for the decoder to reject.
  static func rewriteIDs(in data: Data, toBase64: Bool) throws -> Data {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw OTLPCodecError.malformed("request body is not JSON")
    }
    guard object is [String: Any] else {
      throw OTLPCodecError.malformed("request body is not a JSON object")
    }
    func walk(_ value: Any) -> Any {
      if let dictionary = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (key, child) in dictionary {
          if idKeys.contains(key), let text = child as? String {
            let converted = toBase64 ? hexToBase64(text) : base64ToHex(text)
            result[key] = converted ?? text
          } else {
            result[key] = walk(child)
          }
        }
        return result
      }
      if let array = value as? [Any] { return array.map(walk) }
      return value
    }
    return try JSONSerialization.data(withJSONObject: walk(object), options: [.sortedKeys])
  }

  static func hexToBase64(_ hex: String) -> String? {
    guard let bytes = hexBytes(hex) else { return nil }
    return Data(bytes).base64EncodedString()
  }

  static func base64ToHex(_ text: String) -> String? {
    guard let data = Data(base64Encoded: text) else { return nil }
    return hexString(data)
  }

  static func hexBytes(_ hex: String) -> [UInt8]? {
    let scalars = Array(hex.utf8)
    guard scalars.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(scalars.count / 2)
    func nibble(_ c: UInt8) -> UInt8? {
      switch c {
      case 48...57: return c - 48
      case 97...102: return c - 87
      case 65...70: return c - 55
      default: return nil
      }
    }
    var index = 0
    while index < scalars.count {
      guard let high = nibble(scalars[index]), let low = nibble(scalars[index + 1]) else {
        return nil
      }
      bytes.append(high << 4 | low)
      index += 2
    }
    return bytes
  }

  static func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Responses

  /// A successful export's response body: empty unless something was
  /// rejected, in which case it carries OTLP's partial success.
  static func successBody(
    signal: TelemetrySignal, rejected: Int, message: String, encoding: OTLPEncoding
  ) -> Data {
    do {
      switch signal {
      case .metrics:
        var response = OTLPMetricsResponse()
        if rejected > 0 || !message.isEmpty {
          response.partialSuccess.rejectedDataPoints = Int64(rejected)
          response.partialSuccess.errorMessage = message
        }
        return try encode(response, as: encoding)
      case .logs:
        var response = OTLPLogsResponse()
        if rejected > 0 || !message.isEmpty {
          response.partialSuccess.rejectedLogRecords = Int64(rejected)
          response.partialSuccess.errorMessage = message
        }
        return try encode(response, as: encoding)
      case .traces:
        var response = OTLPTraceResponse()
        if rejected > 0 || !message.isEmpty {
          response.partialSuccess.rejectedSpans = Int64(rejected)
          response.partialSuccess.errorMessage = message
        }
        return try encode(response, as: encoding)
      }
    } catch {
      return encoding == .json ? Data("{}".utf8) : Data()
    }
  }

  /// The `google.rpc.Status` every OTLP/HTTP error response carries: code
  /// and message, written by hand rather than generating googleapis for two
  /// fields.
  static func statusBody(code: Int32, message: String, encoding: OTLPEncoding) -> Data {
    switch encoding {
    case .json:
      let object: [String: Any] = ["code": Int(code), "message": message]
      return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        ?? Data("{}".utf8)
    case .protobuf:
      var data = Data()
      if code != 0 {
        data.append(0x08)
        appendVarint(UInt64(UInt32(bitPattern: code)), to: &data)
      }
      let text = Data(message.utf8)
      if !text.isEmpty {
        data.append(0x12)
        appendVarint(UInt64(text.count), to: &data)
        data.append(text)
      }
      return data
    }
  }

  private static func appendVarint(_ value: UInt64, to data: inout Data) {
    var value = value
    while value >= 0x80 {
      data.append(UInt8(value & 0x7F) | 0x80)
      value >>= 7
    }
    data.append(UInt8(value))
  }

  // MARK: gzip

  /// Inflate a gzip body, refusing to produce more than `limit` bytes. Every
  /// member of a multi-member stream is read; a truncated or corrupt stream
  /// is malformed.
  static func gunzip(_ data: Data, limit: Int) throws -> Data {
    guard !data.isEmpty else { return Data() }
    var stream = z_stream()
    guard
      inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw OTLPCodecError.malformed("gzip decoder unavailable") }
    defer { inflateEnd(&stream) }
    var output = Data()
    let chunk = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: chunk)
    var input = [UInt8](data)
    let inputCount = input.count
    return try input.withUnsafeMutableBufferPointer { inputBuffer -> Data in
      stream.next_in = inputBuffer.baseAddress
      stream.avail_in = uInt(inputCount)
      while true {
        let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
          stream.next_out = out.baseAddress
          stream.avail_out = uInt(chunk)
          return inflate(&stream, Z_NO_FLUSH)
        }
        let produced = chunk - Int(stream.avail_out)
        if output.count + produced > limit { throw OTLPCodecError.tooLarge }
        output.append(contentsOf: buffer[0..<produced])
        switch status {
        case Z_STREAM_END:
          // Another member may follow; anything else is trailing garbage.
          guard stream.avail_in > 0 else { return output }
          guard inflateReset(&stream) == Z_OK else {
            throw OTLPCodecError.malformed("invalid gzip body")
          }
        case Z_OK:
          if stream.avail_in == 0, produced == 0 {
            throw OTLPCodecError.malformed("truncated gzip body")
          }
        case Z_BUF_ERROR where stream.avail_in == 0:
          throw OTLPCodecError.malformed("truncated gzip body")
        default:
          throw OTLPCodecError.malformed("invalid gzip body")
        }
      }
    }
  }

  /// gzip at the default level: the exporter's `compression = "gzip"`, and
  /// the tests' sender.
  static func gzip(_ data: Data) -> Data {
    var stream = z_stream()
    guard
      deflateInit2_(
        &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { return Data() }
    defer { deflateEnd(&stream) }
    var input = [UInt8](data)
    let inputCount = input.count
    var output = Data()
    let chunk = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: chunk)
    input.withUnsafeMutableBufferPointer { inputBuffer in
      stream.next_in = inputBuffer.baseAddress
      stream.avail_in = uInt(inputCount)
      while true {
        let status = buffer.withUnsafeMutableBufferPointer { out -> Int32 in
          stream.next_out = out.baseAddress
          stream.avail_out = uInt(chunk)
          return deflate(&stream, Z_FINISH)
        }
        output.append(contentsOf: buffer[0..<(chunk - Int(stream.avail_out))])
        if status == Z_STREAM_END || status != Z_OK { break }
      }
    }
    return output
  }
}

/// OTLP attribute values as the store and the help page show them.
enum OTLPValues {
  /// Longest attribute value kept, in characters.
  static let maxValueLength = 256
  /// Most attributes kept per resource, scope or point.
  static let maxAttributes = 64

  static func string(_ value: OTLPAnyValue, limit: Int = maxValueLength) -> String {
    let text: String
    switch value.value {
    case .stringValue(let string): text = string
    case .boolValue(let bool): text = bool ? "true" : "false"
    case .intValue(let int): text = String(int)
    case .doubleValue(let double): text = TelemetryNumber.format(double)
    case .bytesValue(let bytes): text = OTLPCodec.hexString(bytes)
    case .arrayValue(let array):
      text =
        "[" + array.values.prefix(32).map { string($0, limit: limit) }.joined(separator: ",")
        + "]"
    case .kvlistValue(let list):
      text =
        "{"
        + list.values.prefix(32).map { "\($0.key)=\(string($0.value, limit: limit))" }
        .joined(separator: ",") + "}"
    case .stringValueStrindex(let index): text = "#\(index)"
    case nil: text = ""
    }
    return text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  static func attributes(_ list: [OTLPKeyValue]) -> [String: String] {
    var result: [String: String] = [:]
    for pair in list.prefix(maxAttributes) where !pair.key.isEmpty {
      result[String(pair.key.prefix(maxValueLength))] = string(pair.value)
    }
    return result
  }

  static func keyValues(_ attributes: [String: String]) -> [OTLPKeyValue] {
    attributes.keys.sorted().map { key in
      var pair = OTLPKeyValue()
      pair.key = key
      pair.value.stringValue = attributes[key] ?? ""
      return pair
    }
  }
}
