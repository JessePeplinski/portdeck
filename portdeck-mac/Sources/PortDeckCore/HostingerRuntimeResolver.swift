import Foundation

public protocol HostingerRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct HostingerRuntimeResolver: HostingerRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "3.7.0",
    maximumExclusive: "4.0.0"
  )
  public static let installCommand = "brew install hostinger/tap/hostinger"
  public static let documentationURL = "https://github.com/hostinger/api-cli"
  public static let overrideEnvironmentKey = "PORTDECK_HOSTINGER_BIN"
  public static let executableName = "hostinger"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/hostinger", "/usr/local/bin/hostinger"],
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
        throw HostingerCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw HostingerCLIError.missingCLI
    }
  }
}
