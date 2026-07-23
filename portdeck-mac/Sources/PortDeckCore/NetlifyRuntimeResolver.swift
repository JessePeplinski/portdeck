import Foundation

public protocol NetlifyRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct NetlifyRuntimeResolver: NetlifyRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "26.2.0",
    maximumExclusive: "27.0.0"
  )
  public static let minimumNodeVersion = "20.12.2"
  public static let installCommand = "brew install netlify-cli"
  public static let documentationURL = "https://docs.netlify.com/api-and-cli-guides/cli-guides/get-started-with-cli/"
  public static let executableName = "netlify"
  public static let overrideEnvironmentKey = "PORTDECK_NETLIFY_BIN"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/netlify", "/usr/local/bin/netlify"],
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
        throw NetlifyCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw NetlifyCLIError.missingCLI
    }
  }
}
