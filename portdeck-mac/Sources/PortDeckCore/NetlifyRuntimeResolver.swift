import Foundation

public protocol NetlifyRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct NetlifyRuntimeResolver: NetlifyRuntimeResolving, @unchecked Sendable {
  public static let pinnedVersion = "26.2.0"
  public static let minimumNodeVersion = "20.12.2"
  public static let executableName = "netlify"
  public static let overrideEnvironmentKey = "PORTDECK_NETLIFY_BIN"
  public static let bundledRelativePath = "ProviderRuntimes/netlify/bin/netlify"
  public static let developmentRelativePath = "node_modules/.bin/netlify"

  private let environment: [String: String]
  private let bundleResourceURL: URL?
  private let developmentSearchRoots: [URL]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    developmentSearchRoots: [URL] = NetlifyRuntimeResolver.defaultDevelopmentSearchRoots(),
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.bundleResourceURL = bundleResourceURL
    self.developmentSearchRoots = developmentSearchRoots
    self.fileManager = fileManager
  }

  public func resolveExecutableURL() throws -> URL {
    if let override = environment[Self.overrideEnvironmentKey] {
      let overrideURL = URL(fileURLWithPath: override)
      guard fileManager.isExecutableFile(atPath: overrideURL.path) else {
        throw NetlifyCLIError.missingRuntime
      }
      return overrideURL
    }

    if let bundledURL = bundleResourceURL?.appendingPathComponent(Self.bundledRelativePath),
      fileManager.isExecutableFile(atPath: bundledURL.path)
    {
      return bundledURL
    }

    if PackagedRuntimeBoundary.requiresBundledRuntime(
      bundleResourceURL: bundleResourceURL,
      fileManager: fileManager
    ) {
      throw NetlifyCLIError.missingRuntime
    }

    for root in developmentSearchRoots {
      var directory = root.standardizedFileURL
      for _ in 0..<12 {
        let candidate = directory.appendingPathComponent(Self.developmentRelativePath)
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
      }
    }

    throw NetlifyCLIError.missingRuntime
  }

  public static func defaultDevelopmentSearchRoots() -> [URL] {
    var roots: [URL] = []
    if let executableURL = Bundle.main.executableURL {
      roots.append(executableURL.deletingLastPathComponent())
    }
    roots.append(Bundle.main.bundleURL)
    return roots
  }
}
