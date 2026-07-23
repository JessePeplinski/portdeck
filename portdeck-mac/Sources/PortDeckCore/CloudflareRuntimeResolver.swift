import Foundation

public protocol CloudflareRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct CloudflareRuntimeResolver: CloudflareRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "4.111.0",
    maximumExclusive: "5.0.0"
  )
  public static let installCommand = "npm install --global wrangler@4"
  public static let documentationURL = "https://developers.cloudflare.com/workers/wrangler/install-and-update/"
  public static let overrideEnvironmentKey = "PORTDECK_WRANGLER_BIN"
  public static let executableName = "wrangler"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/wrangler", "/usr/local/bin/wrangler"],
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
        throw CloudflareCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw CloudflareCLIError.missingCLI
    }
  }
}
