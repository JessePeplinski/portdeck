import Foundation

public protocol SupabaseRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct SupabaseRuntimeResolver: SupabaseRuntimeResolving, @unchecked Sendable {
  public static let pinnedVersion = "2.109.1"
  public static let overrideEnvironmentKey = "PORTDECK_SUPABASE_BIN"
  public static let bundledRelativePath = "ProviderRuntimes/supabase/bin/supabase"

  private let environment: [String: String]
  private let bundleResourceURL: URL?
  private let developmentSearchRoots: [URL]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    developmentSearchRoots: [URL] = SupabaseRuntimeResolver.defaultDevelopmentSearchRoots(),
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
        throw SupabaseCLIError.missingRuntime
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
      throw SupabaseCLIError.missingRuntime
    }

    for root in developmentSearchRoots {
      var directory = root.standardizedFileURL
      for _ in 0..<12 {
        let candidate = directory.appendingPathComponent("node_modules/.bin/supabase")
        if fileManager.isExecutableFile(atPath: candidate.path) {
          return candidate
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
      }
    }

    throw SupabaseCLIError.missingRuntime
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
