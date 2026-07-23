import Foundation

public protocol ConvexRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct ConvexRuntimeResolver: ConvexRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "1.42.1",
    maximumExclusive: "2.0.0"
  )
  public static let installCommand = "npm install --global convex@1"
  public static let documentationURL = "https://docs.convex.dev/cli"
  public static let overrideEnvironmentKey = "PORTDECK_CONVEX_BIN"
  public static let executableName = "convex"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/convex", "/usr/local/bin/convex"],
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
        throw ConvexCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw ConvexCLIError.missingCLI
    }
  }
}
