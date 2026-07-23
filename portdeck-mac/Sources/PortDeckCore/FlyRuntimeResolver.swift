import Foundation

public protocol FlyRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct FlyRuntimeResolver: FlyRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "0.4.71",
    maximumExclusive: "0.5.0"
  )
  public static let installCommand = "brew install flyctl"
  public static let documentationURL = "https://fly.io/docs/flyctl/install/"
  public static let overrideEnvironmentKey = "PORTDECK_FLY_BIN"
  public static let executableName = "flyctl"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/flyctl", "/usr/local/bin/flyctl"],
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
        throw FlyCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw FlyCLIError.missingCLI
    }
  }
}
