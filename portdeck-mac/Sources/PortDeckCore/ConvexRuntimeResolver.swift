import Foundation

public protocol ConvexRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct ConvexRuntimeResolver: ConvexRuntimeResolving, @unchecked Sendable {
  public static let pinnedVersion = "1.42.1"
  public static let overrideEnvironmentKey = "PORTDECK_CONVEX_BIN"
  public static let bundledRelativePath = "ProviderRuntimes/convex/bin/convex"

  private let environment: [String: String]
  private let bundleResourceURL: URL?
  private let developmentSearchRoots: [URL]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    developmentSearchRoots: [URL] = ConvexRuntimeResolver.defaultDevelopmentSearchRoots(),
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
        throw ConvexCLIError.missingRuntime
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
      throw ConvexCLIError.missingRuntime
    }

    for root in developmentSearchRoots {
      var directory = root.standardizedFileURL
      for _ in 0..<12 {
        let candidate = directory.appendingPathComponent("node_modules/.bin/convex")
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path {
          break
        }
        directory = parent
      }
    }

    throw ConvexCLIError.missingRuntime
  }

  public static func defaultDevelopmentSearchRoots() -> [URL] {
    var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    if let executableURL = Bundle.main.executableURL {
      roots.append(executableURL.deletingLastPathComponent())
    }
    roots.append(Bundle.main.bundleURL)
    return roots
  }
}
