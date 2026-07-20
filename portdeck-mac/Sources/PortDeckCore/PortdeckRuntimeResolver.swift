import Foundation

public struct PortdeckRuntime: Equatable, Sendable {
  public let nodeURL: URL
  public let cliURL: URL

  public init(nodeURL: URL, cliURL: URL) {
    self.nodeURL = nodeURL
    self.cliURL = cliURL
  }
}

public protocol PortdeckRuntimeResolving: Sendable {
  func resolveRuntime() throws -> PortdeckRuntime
}

public struct PortdeckRuntimeResolver: PortdeckRuntimeResolving, @unchecked Sendable {
  public static let nodeOverrideEnvironmentKey = "PORTDECK_NODE"
  public static let cliOverrideEnvironmentKey = "PORTDECK_CLI"
  public static let packagedRuntimeRelativePath = "PortDeckRuntime"
  public static let packagedNodeRelativePath = "bin/node"
  public static let packagedCLIRelativePath = "portdeck-cli.js"

  private let environment: [String: String]
  private let bundleResourceURL: URL?
  private let developmentSearchRoots: [URL]
  private let systemNodeSearchPaths: [String]
  private let fileManager: FileManager

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = Bundle.main.resourceURL,
    developmentSearchRoots: [URL] = PortdeckRuntimeResolver.defaultDevelopmentSearchRoots(),
    systemNodeSearchPaths: [String] = PortdeckRuntimeResolver.defaultSystemNodeSearchPaths,
    fileManager: FileManager = .default
  ) {
    self.environment = environment
    self.bundleResourceURL = bundleResourceURL
    self.developmentSearchRoots = developmentSearchRoots
    self.systemNodeSearchPaths = systemNodeSearchPaths
    self.fileManager = fileManager
  }

  public func resolveRuntime() throws -> PortdeckRuntime {
    let overrideCLI = try overrideURL(
      key: Self.cliOverrideEnvironmentKey,
      mustBeExecutable: false
    )
    let overrideNode = try overrideURL(
      key: Self.nodeOverrideEnvironmentKey,
      mustBeExecutable: true
    )

    if let packagedRoot = packagedRuntimeRoot()
      ?? authoritativePackagedRuntimeRoot()
    {
      let cliURL = try overrideCLI ?? requiredPackagedURL(
        packagedRoot.appendingPathComponent(Self.packagedCLIRelativePath),
        component: "helper",
        mustBeExecutable: false
      )
      let nodeURL = try overrideNode ?? requiredPackagedURL(
        packagedRoot.appendingPathComponent(Self.packagedNodeRelativePath),
        component: "Node runtime",
        mustBeExecutable: true
      )
      return PortdeckRuntime(nodeURL: nodeURL, cliURL: cliURL)
    }

    guard let cliURL = overrideCLI ?? developmentCLIURL() else {
      throw PortdeckRuntimeResolverError.missingCLI
    }
    guard let nodeURL = overrideNode ?? systemNodeURL() else {
      throw PortdeckRuntimeResolverError.missingNode
    }
    return PortdeckRuntime(nodeURL: nodeURL, cliURL: cliURL)
  }

  public static func defaultDevelopmentSearchRoots() -> [URL] {
    var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
    if let executableURL = Bundle.main.executableURL {
      roots.append(executableURL.deletingLastPathComponent())
    }
    roots.append(Bundle.main.bundleURL)
    return roots
  }

  public static let defaultSystemNodeSearchPaths = [
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    "/usr/bin/node"
  ]

  private func overrideURL(key: String, mustBeExecutable: Bool) throws -> URL? {
    guard let value = environment[key] else { return nil }
    let url = URL(fileURLWithPath: value)
    guard !value.isEmpty, usableFile(at: url, mustBeExecutable: mustBeExecutable) else {
      throw PortdeckRuntimeResolverError.invalidOverride(variable: key, path: value)
    }
    return url
  }

  private func packagedRuntimeRoot() -> URL? {
    guard let root = bundleResourceURL?.appendingPathComponent(Self.packagedRuntimeRelativePath) else {
      return nil
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return nil
    }
    return root
  }

  private func authoritativePackagedRuntimeRoot() -> URL? {
    guard PackagedRuntimeBoundary.requiresBundledRuntime(
      bundleResourceURL: bundleResourceURL,
      fileManager: fileManager
    ) else {
      return nil
    }
    return bundleResourceURL?.appendingPathComponent(Self.packagedRuntimeRelativePath)
  }

  private func requiredPackagedURL(
    _ url: URL,
    component: String,
    mustBeExecutable: Bool
  ) throws -> URL {
    guard usableFile(at: url, mustBeExecutable: mustBeExecutable) else {
      throw PortdeckRuntimeResolverError.incompletePackagedRuntime(component: component, path: url.path)
    }
    return url
  }

  private func developmentCLIURL() -> URL? {
    for root in developmentSearchRoots {
      var directory = root.standardizedFileURL
      for _ in 0..<10 {
        let candidates = [
          directory.appendingPathComponent("portdeck-app/dist/cli.js"),
          directory.appendingPathComponent("../portdeck-app/dist/cli.js").standardizedFileURL
        ]
        if let candidate = candidates.first(where: { usableFile(at: $0, mustBeExecutable: false) }) {
          return candidate
        }

        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
      }
    }
    return nil
  }

  private func systemNodeURL() -> URL? {
    systemNodeSearchPaths
      .map(URL.init(fileURLWithPath:))
      .first(where: { usableFile(at: $0, mustBeExecutable: true) })
  }

  private func usableFile(at url: URL, mustBeExecutable: Bool) -> Bool {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      return false
    }
    return !mustBeExecutable || fileManager.isExecutableFile(atPath: url.path)
  }
}

public enum PortdeckRuntimeResolverError: LocalizedError, Equatable {
  case invalidOverride(variable: String, path: String)
  case incompletePackagedRuntime(component: String, path: String)
  case missingCLI
  case missingNode

  public var errorDescription: String? {
    switch self {
    case .invalidOverride(let variable, let path):
      return "\(variable) points to an unavailable runtime path: \(path)"
    case .incompletePackagedRuntime(let component, let path):
      return "The packaged PortDeck \(component) is unavailable at \(path). Rebuild the release app."
    case .missingCLI:
      return "Could not find portdeck-app/dist/cli.js. Run npm run build from the repo root."
    case .missingNode:
      return "Could not find a Node.js runtime. Set PORTDECK_NODE or install Node.js for source development."
    }
  }
}
