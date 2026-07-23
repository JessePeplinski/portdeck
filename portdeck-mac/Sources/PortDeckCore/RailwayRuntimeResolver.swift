import Foundation

public protocol RailwayRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct RailwayRuntimeResolver: RailwayRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "5.26.2",
    maximumExclusive: "6.0.0"
  )
  public static let installCommand = "brew install railway"
  public static let documentationURL = "https://docs.railway.com/guides/cli"
  public static let overrideEnvironmentKey = "PORTDECK_RAILWAY_BIN"
  public static let executableName = "railway"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/railway", "/usr/local/bin/railway"],
    fileManager: FileManager = .default,
    loginShellLookup: @escaping ProviderCLILoginShellLookup = ExternalProviderCLIResolver.lookupInLoginShell
  ) {
    resolver = ExternalProviderCLIResolver(
      executableName: Self.executableName,
      overrideEnvironmentKey: Self.overrideEnvironmentKey,
      environment: environment,
      executableSearchPaths: executableSearchPaths,
      fileManager: fileManager,
      loginShellLookup: loginShellLookup
    )
  }

  public func resolveExecutableURL() throws -> URL {
    do {
      guard let executableURL = try resolver.resolveExecutableURL() else {
        throw RailwayCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw RailwayCLIError.missingCLI
    }
  }
}
