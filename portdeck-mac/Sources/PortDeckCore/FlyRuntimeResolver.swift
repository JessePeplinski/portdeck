import Foundation

public protocol FlyRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct FlyRuntimeResolver: FlyRuntimeResolving, @unchecked Sendable {
  public static let pinnedVersion = "0.4.71"
  public static let overrideEnvironmentKey = "PORTDECK_FLY_BIN"
  public static let bundledRelativePath = "ProviderRuntimes/fly/bin/flyctl"
  public static let developmentRelativePath = ".build/provider-runtimes/fly/bin/flyctl"

  private let environment: [String: String]
  private let bundleResourceURL: URL?
  private let developmentSearchRoots: [URL]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    developmentSearchRoots: [URL] = FlyRuntimeResolver.defaultDevelopmentSearchRoots(),
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
        throw FlyCLIError.missingRuntime
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
      throw FlyCLIError.missingRuntime
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

    throw FlyCLIError.missingRuntime
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
