import Foundation

public protocol SupabaseRuntimeResolving: Sendable {
  func resolveExecutableURL() throws -> URL
}

public struct SupabaseRuntimeResolver: SupabaseRuntimeResolving, @unchecked Sendable {
  public static let supportedVersionRange = SupportedProviderCLIVersionRange(
    minimumInclusive: "2.109.1",
    maximumExclusive: "3.0.0"
  )
  public static let installCommand = "brew install supabase/tap/supabase"
  public static let documentationURL = "https://supabase.com/docs/guides/local-development/cli/getting-started"
  public static let overrideEnvironmentKey = "PORTDECK_SUPABASE_BIN"
  public static let executableName = "supabase"

  private let resolver: ExternalProviderCLIResolver

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executableSearchPaths: [String] = ["/opt/homebrew/bin/supabase", "/usr/local/bin/supabase"],
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
        throw SupabaseCLIError.missingCLI
      }
      return executableURL
    } catch is ExternalProviderCLIResolutionError {
      throw SupabaseCLIError.missingCLI
    }
  }
}
