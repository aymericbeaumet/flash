import Foundation

/// A JSON Schema (draft-07) validator for the keywords Flash's published
/// schemas use: `type`, `const`, `enum`, `properties`, `required`,
/// `additionalProperties`, `items`, `minItems`, `maxItems`, `uniqueItems`,
/// `minLength`, `maxLength`, `minimum`, `pattern`, `oneOf`, `anyOf`,
/// `allOf` and `$ref` (to `#/definitions/…` and to sibling files). A
/// keyword it does not know fails validation, so a schema cannot quietly
/// outgrow it.
struct JSONSchemaValidator {
  /// Schema documents by file name (`hello.schema.json`).
  let documents: [String: [String: Any]]

  static let keywords: Set<String> = [
    "$schema", "$id", "title", "description", "definitions", "type", "const", "enum",
    "properties", "required", "additionalProperties", "items", "minItems", "maxItems",
    "uniqueItems", "minLength", "maxLength", "minimum", "pattern", "oneOf", "anyOf", "allOf",
    "$ref",
  ]

  init(directory: URL) throws {
    var documents: [String: [String: Any]] = [:]
    for file in try FileManager.default.contentsOfDirectory(atPath: directory.path)
    where file.hasSuffix(".schema.json") {
      let data = try Data(contentsOf: directory.appendingPathComponent(file))
      guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CocoaError(.fileReadCorruptFile)
      }
      documents[file] = object
    }
    self.documents = documents
  }

  /// Every problem `value` has against the document `file`; empty when it
  /// validates.
  func problems(_ value: Any, against file: String) -> [String] {
    guard let schema = documents[file] else { return ["no schema \(file)"] }
    var problems: [String] = []
    validate(value, schema, document: file, path: "$", into: &problems)
    return problems
  }

  func problems(json: Data, against file: String) -> [String] {
    guard let value = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed])
    else { return ["not JSON"] }
    return problems(value, against: file)
  }

  private func validate(
    _ value: Any, _ schema: [String: Any], document: String, path: String,
    into problems: inout [String]
  ) {
    for key in schema.keys where !Self.keywords.contains(key) {
      problems.append("\(path): unsupported keyword \(key)")
    }
    if let reference = schema["$ref"] as? String {
      guard let (target, targetDocument) = resolve(reference, from: document) else {
        problems.append("\(path): unresolved $ref \(reference)")
        return
      }
      validate(value, target, document: targetDocument, path: path, into: &problems)
    }
    if let all = schema["allOf"] as? [[String: Any]] {
      for option in all { validate(value, option, document: document, path: path, into: &problems) }
    }
    if let any = schema["anyOf"] as? [[String: Any]],
      !any.contains(where: { matches(value, $0, document: document, path: path) })
    {
      problems.append("\(path): matches none of anyOf")
    }
    if let one = schema["oneOf"] as? [[String: Any]] {
      let count = one.filter { matches(value, $0, document: document, path: path) }.count
      if count != 1 { problems.append("\(path): matches \(count) of oneOf, not exactly one") }
    }
    if let constant = schema["const"], !Self.equal(value, constant) {
      problems.append("\(path): must be \(constant)")
    }
    if let values = schema["enum"] as? [Any], !values.contains(where: { Self.equal(value, $0) }) {
      problems.append("\(path): \(value) is not one of the enum")
    }
    if let type = schema["type"] {
      let types = (type as? [String]) ?? [(type as? String) ?? ""]
      guard types.contains(where: { Self.isType(value, $0) }) else {
        problems.append("\(path): must be \(types.joined(separator: " or "))")
        return
      }
    }
    if let string = value as? String, !Self.isBoolean(value) {
      if let minimum = schema["minLength"] as? Int, string.count < minimum {
        problems.append("\(path): shorter than \(minimum)")
      }
      if let maximum = schema["maxLength"] as? Int, string.count > maximum {
        problems.append("\(path): longer than \(maximum)")
      }
      if let pattern = schema["pattern"] as? String,
        string.range(of: pattern, options: .regularExpression) == nil
      {
        problems.append("\(path): does not match \(pattern)")
      }
    }
    if Self.isType(value, "number"), let number = (value as? NSNumber)?.doubleValue,
      let minimum = (schema["minimum"] as? NSNumber)?.doubleValue, number < minimum
    {
      problems.append("\(path): below \(minimum)")
    }
    if let array = value as? [Any] {
      if let minimum = schema["minItems"] as? Int, array.count < minimum {
        problems.append("\(path): fewer than \(minimum) items")
      }
      if let maximum = schema["maxItems"] as? Int, array.count > maximum {
        problems.append("\(path): more than \(maximum) items")
      }
      if schema["uniqueItems"] as? Bool == true {
        for (index, item) in array.enumerated()
        where array[..<index].contains(where: { Self.equal($0, item) }) {
          problems.append("\(path)[\(index)]: repeated")
        }
      }
      if let items = schema["items"] as? [String: Any] {
        for (index, item) in array.enumerated() {
          validate(item, items, document: document, path: "\(path)[\(index)]", into: &problems)
        }
      }
    }
    if let object = value as? [String: Any] {
      let properties = schema["properties"] as? [String: Any] ?? [:]
      for key in schema["required"] as? [String] ?? [] where object[key] == nil {
        problems.append("\(path).\(key): required")
      }
      for (key, child) in object {
        if let property = properties[key] as? [String: Any] {
          validate(child, property, document: document, path: "\(path).\(key)", into: &problems)
        } else if let additional = schema["additionalProperties"] as? [String: Any] {
          validate(child, additional, document: document, path: "\(path).\(key)", into: &problems)
        } else if schema["additionalProperties"] as? Bool == false {
          problems.append("\(path).\(key): not allowed")
        }
      }
    }
  }

  private func matches(_ value: Any, _ schema: [String: Any], document: String, path: String)
    -> Bool
  {
    var nested: [String] = []
    validate(value, schema, document: document, path: path, into: &nested)
    return nested.isEmpty
  }

  /// `#/definitions/x` in `document`, `other.schema.json`, or
  /// `other.schema.json#/definitions/x`.
  private func resolve(_ reference: String, from document: String) -> (
    [String: Any], String
  )? {
    let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
    let file = parts[0].isEmpty ? document : String(parts[0])
    guard var node: Any = documents[file] else { return nil }
    if parts.count == 2 {
      for component in parts[1].split(separator: "/") {
        guard let next = (node as? [String: Any])?[String(component)] else { return nil }
        node = next
      }
    }
    guard let schema = node as? [String: Any] else { return nil }
    return (schema, file)
  }

  static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  static func isType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "string": return value is String
    case "boolean": return isBoolean(value)
    case "null": return value is NSNull
    case "integer":
      guard let number = value as? NSNumber, !isBoolean(value) else { return false }
      return !CFNumberIsFloatType(number) || number.doubleValue.rounded() == number.doubleValue
    case "number":
      return value is NSNumber && !isBoolean(value)
    default: return false
    }
  }

  static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    if isBoolean(lhs) != isBoolean(rhs) { return false }
    switch (lhs, rhs) {
    case (let a as String, let b as String): return a == b
    case (let a as NSNumber, let b as NSNumber): return a == b
    case (let a as [Any], let b as [Any]):
      return a.count == b.count && zip(a, b).allSatisfy { equal($0, $1) }
    case (let a as [String: Any], let b as [String: Any]):
      return a.count == b.count
        && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }
    case (is NSNull, is NSNull): return true
    default: return false
    }
  }
}
