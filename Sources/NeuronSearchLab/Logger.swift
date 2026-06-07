import Foundation

public enum LogLevel: Int, CaseIterable, Sendable {
  case trace = 10
  case debug = 20
  case info = 30
  case warn = 40
  case error = 50
  case fatal = 60

  public var name: String {
    switch self {
    case .trace:
      return "TRACE"
    case .debug:
      return "DEBUG"
    case .info:
      return "INFO"
    case .warn:
      return "WARN"
    case .error:
      return "ERROR"
    case .fatal:
      return "FATAL"
    }
  }
}

public struct StructuredLogEntry: Sendable {
  public let level: LogLevel
  public let levelValue: Int
  public let message: String
  public let timestamp: String
  public let context: JSONObject?
}

public typealias LoggerTransport = @Sendable (StructuredLogEntry) -> Void

public struct LoggerConfiguration: Sendable {
  public var level: LogLevel
  public var enableNetworkBodyLogging: Bool
  public var enablePerformanceLogging: Bool
  public var transport: LoggerTransport?
  public var redactKeys: Set<String>

  public init(
    level: LogLevel = .info,
    enableNetworkBodyLogging: Bool = false,
    enablePerformanceLogging: Bool = false,
    transport: LoggerTransport? = nil,
    redactKeys: Set<String> = ["accessToken", "authorization", "Authorization"]
  ) {
    self.level = level
    self.enableNetworkBodyLogging = enableNetworkBodyLogging
    self.enablePerformanceLogging = enablePerformanceLogging
    self.transport = transport
    self.redactKeys = redactKeys
  }
}

public final class SDKLogger: @unchecked Sendable {
  public static let shared = SDKLogger()

  private let lock = NSLock()
  private var configuration = LoggerConfiguration(transport: SDKLogger.defaultTransport)

  private init() {}

  public func configure(_ configuration: LoggerConfiguration = LoggerConfiguration()) {
    lock.lock()
    self.configuration = configuration
    lock.unlock()
  }

  public func shouldLog(_ level: LogLevel) -> Bool {
    let configuredLevel: LogLevel
    lock.lock()
    configuredLevel = configuration.level
    lock.unlock()
    return level.rawValue >= configuredLevel.rawValue
  }

  public func isPerformanceLoggingEnabled() -> Bool {
    let config: LoggerConfiguration
    lock.lock()
    config = configuration
    lock.unlock()
    return config.enablePerformanceLogging && shouldLog(.debug)
  }

  public func canLogNetworkPayloads(_ level: LogLevel) -> Bool {
    let config: LoggerConfiguration
    lock.lock()
    config = configuration
    lock.unlock()
    return config.enableNetworkBodyLogging &&
      shouldLog(level) &&
      level.rawValue <= LogLevel.debug.rawValue
  }

  public func trace(_ message: String, context: JSONObject? = nil) {
    log(.trace, message, context: context)
  }

  public func debug(_ message: String, context: JSONObject? = nil) {
    log(.debug, message, context: context)
  }

  public func info(_ message: String, context: JSONObject? = nil) {
    log(.info, message, context: context)
  }

  public func warn(_ message: String, context: JSONObject? = nil) {
    log(.warn, message, context: context)
  }

  public func error(_ message: String, context: JSONObject? = nil) {
    log(.error, message, context: context)
  }

  public func fatal(_ message: String, context: JSONObject? = nil) {
    log(.fatal, message, context: context)
  }

  private func log(_ level: LogLevel, _ message: String, context: JSONObject?) {
    let config: LoggerConfiguration
    lock.lock()
    config = configuration
    lock.unlock()

    guard level.rawValue >= config.level.rawValue else {
      return
    }

    let entry = StructuredLogEntry(
      level: level,
      levelValue: level.rawValue,
      message: message,
      timestamp: iso8601String(),
      context: sanitize(context, level: level, config: config)
    )

    (config.transport ?? SDKLogger.defaultTransport)(entry)
  }

  private func sanitize(
    _ context: JSONObject?,
    level: LogLevel,
    config: LoggerConfiguration
  ) -> JSONObject? {
    guard let context else {
      return nil
    }

    var sanitized: JSONObject = [:]
    for (key, value) in context {
      if config.redactKeys.contains(key) {
        sanitized[key] = "[REDACTED]"
      } else if (key == "requestBody" || key == "responseBody") &&
        !(config.enableNetworkBodyLogging && level.rawValue <= LogLevel.debug.rawValue) {
        continue
      } else {
        sanitized[key] = value
      }
    }
    return sanitized.isEmpty ? nil : sanitized
  }

  private static let defaultTransport: LoggerTransport = { entry in
    var line = "[NeuronSDK][\(entry.level.name)] \(entry.message)"
    if let context = entry.context, !context.isEmpty,
       let data = try? JSONEncoder().encode(JSONValue.object(context)),
       let json = String(data: data, encoding: .utf8) {
      line += " \(json)"
    }
    print(line)
  }
}

public let logger = SDKLogger.shared

public func configureLogger(_ configuration: LoggerConfiguration) {
  SDKLogger.shared.configure(configuration)
}
