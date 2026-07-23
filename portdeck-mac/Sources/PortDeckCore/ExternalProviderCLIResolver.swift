import Foundation

public struct ProviderCLIVersion: Comparable, CustomStringConvertible, Sendable {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init?(string: String) {
    let parts = string.split(separator: ".")
    guard parts.count == 3,
      let major = Int(parts[0]),
      let minor = Int(parts[1]),
      let patch = Int(parts[2])
    else {
      return nil
    }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (left: ProviderCLIVersion, right: ProviderCLIVersion) -> Bool {
    if left.major != right.major { return left.major < right.major }
    if left.minor != right.minor { return left.minor < right.minor }
    return left.patch < right.patch
  }

  public static func first(in value: String) -> ProviderCLIVersion? {
    guard let expression = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)\.(\d+)(?![-+0-9])"#),
      let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
      let range = Range(match.range, in: value)
    else {
      return nil
    }
    return ProviderCLIVersion(string: String(value[range]))
  }
}

public struct SupportedProviderCLIVersionRange: Equatable, Sendable {
  public let minimumInclusive: ProviderCLIVersion
  public let maximumExclusive: ProviderCLIVersion

  public init(minimumInclusive: String, maximumExclusive: String) {
    guard let minimum = ProviderCLIVersion(string: minimumInclusive),
      let maximum = ProviderCLIVersion(string: maximumExclusive),
      minimum < maximum
    else {
      preconditionFailure("Provider CLI version ranges must contain valid ascending semantic versions.")
    }
    self.minimumInclusive = minimum
    self.maximumExclusive = maximum
  }

  public func contains(_ version: ProviderCLIVersion) -> Bool {
    version >= minimumInclusive && version < maximumExclusive
  }

  public var displayName: String {
    "\(minimumInclusive) or newer, before \(maximumExclusive)"
  }
}

public typealias ProviderCLILoginShellLookup =
  @Sendable (_ shellURL: URL, _ executableName: String) -> String?

public enum ExternalProviderCLIResolutionError: Error, Equatable {
  case invalidOverride(variable: String, path: String)
}

public struct ExternalProviderCLIResolver: @unchecked Sendable {
  private let executableName: String
  private let overrideEnvironmentKey: String
  private let environment: [String: String]
  private let executableSearchPaths: [String]
  private let fileManager: FileManager
  private let loginShellLookup: ProviderCLILoginShellLookup

  public init(
    executableName: String,
    overrideEnvironmentKey: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String],
    fileManager: FileManager = .default,
    loginShellLookup: @escaping ProviderCLILoginShellLookup = ExternalProviderCLIResolver.lookupInLoginShell
  ) {
    self.executableName = executableName
    self.overrideEnvironmentKey = overrideEnvironmentKey
    self.environment = environment
    self.executableSearchPaths = executableSearchPaths
    self.fileManager = fileManager
    self.loginShellLookup = loginShellLookup
  }

  public func resolveExecutableURL() throws -> URL? {
    if let override = environment[overrideEnvironmentKey] {
      guard fileManager.isExecutableFile(atPath: override) else {
        throw ExternalProviderCLIResolutionError.invalidOverride(
          variable: overrideEnvironmentKey,
          path: override
        )
      }
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    let shellPath = environment["SHELL"] ?? "/bin/zsh"
    if fileManager.isExecutableFile(atPath: shellPath),
      let path = loginShellLookup(URL(fileURLWithPath: shellPath), executableName),
      fileManager.isExecutableFile(atPath: path)
    {
      return URL(fileURLWithPath: path).standardizedFileURL
    }

    for path in executableSearchPaths where fileManager.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path).standardizedFileURL
    }

    return nil
  }

  public static func lookupInLoginShell(shellURL: URL, executableName: String) -> String? {
    let process = Process()
    let stdout = Pipe()
    process.executableURL = shellURL
    process.arguments = ["-lc", "command -v \(executableName)"]
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }

    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }
}

public enum ProviderCLIExecutionEnvironment {
  private static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  public static func make(
    executableURL: URL,
    base: [String: String]
  ) -> [String: String] {
    var result = base
    var seen = Set<String>()
    let entries = [executableURL.deletingLastPathComponent().standardizedFileURL.path]
      + (base["PATH"] ?? fallbackPath).split(separator: ":").map(String.init)
    result["PATH"] = entries
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .joined(separator: ":")
    return result
  }
}
