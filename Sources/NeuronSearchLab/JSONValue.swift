import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case object(JSONObject)
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension JSONValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .int(value)
  }
}

extension JSONValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .double(value)
  }
}

extension JSONValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) {
    self = .bool(value)
  }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) {
    self = .array(elements)
  }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(uniqueKeysWithValues: elements))
  }
}

public extension JSONValue {
  var stringValue: String? {
    switch self {
    case .string(let value):
      return value
    case .int(let value):
      return String(value)
    case .double(let value):
      return String(value)
    case .bool(let value):
      return value ? "true" : "false"
    case .object, .array, .null:
      return nil
    }
  }

  var intValue: Int? {
    switch self {
    case .int(let value):
      return value
    case .string(let value):
      return Int(value)
    case .double(let value):
      return Int(value)
    case .bool, .object, .array, .null:
      return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case .double(let value):
      return value
    case .int(let value):
      return Double(value)
    case .string(let value):
      return Double(value)
    case .bool, .object, .array, .null:
      return nil
    }
  }

  var boolValue: Bool? {
    switch self {
    case .bool(let value):
      return value
    case .string(let value):
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true":
        return true
      case "false":
        return false
      default:
        return nil
      }
    case .int, .double, .object, .array, .null:
      return nil
    }
  }

  var objectValue: JSONObject? {
    if case .object(let value) = self {
      return value
    }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self {
      return value
    }
    return nil
  }
}

struct DynamicCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(_ stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(stringValue: String) {
    self.init(stringValue)
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

func jsonData(from value: JSONValue) throws -> Data {
  try JSONEncoder().encode(value)
}

func jsonString(from value: JSONValue) throws -> String {
  let data = try jsonData(from: value)
  guard let string = String(data: data, encoding: .utf8) else {
    throw EncodingError.invalidValue(
      value,
      EncodingError.Context(codingPath: [], debugDescription: "Encoded JSON was not UTF-8")
    )
  }
  return string
}

func iso8601String(from date: Date = Date()) -> String {
  ISO8601DateFormatter.neuronSearchLabFormatter.string(from: date)
}

private extension ISO8601DateFormatter {
  static let neuronSearchLabFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
