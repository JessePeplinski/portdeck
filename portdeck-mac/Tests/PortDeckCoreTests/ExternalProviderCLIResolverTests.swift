import Foundation
import Testing
@testable import PortDeckCore

@Test
func externalProviderResolverUsesAuthoritativeOverrideBeforeOtherSources() throws {
  let fixture = try ExternalProviderCLIResolverFixture()
  defer { fixture.remove() }
  let overrideURL = try fixture.makeExecutable("override/provider")
  let shellURL = try fixture.makeExecutable("bin/zsh")
  let shellResult = try fixture.makeExecutable("shell/provider")
  let standardURL = try fixture.makeExecutable("opt/homebrew/bin/provider")

  let resolver = ExternalProviderCLIResolver(
    executableName: "provider",
    overrideEnvironmentKey: "PORTDECK_PROVIDER_BIN",
    environment: [
      "PORTDECK_PROVIDER_BIN": overrideURL.path,
      "SHELL": shellURL.path
    ],
    executableSearchPaths: [standardURL.path],
    loginShellLookup: { _, _ in shellResult.path }
  )

  #expect(try resolver.resolveExecutableURL() == overrideURL.standardizedFileURL)
}

@Test
func externalProviderResolverDoesNotFallBackFromInvalidOverride() throws {
  let fixture = try ExternalProviderCLIResolverFixture()
  defer { fixture.remove() }
  let shellURL = try fixture.makeExecutable("bin/zsh")
  let shellResult = try fixture.makeExecutable("shell/provider")
  let invalidOverride = fixture.root.appendingPathComponent("missing/provider").path

  let resolver = ExternalProviderCLIResolver(
    executableName: "provider",
    overrideEnvironmentKey: "PORTDECK_PROVIDER_BIN",
    environment: [
      "PORTDECK_PROVIDER_BIN": invalidOverride,
      "SHELL": shellURL.path
    ],
    executableSearchPaths: [],
    loginShellLookup: { _, _ in shellResult.path }
  )

  #expect(throws: ExternalProviderCLIResolutionError.invalidOverride(
    variable: "PORTDECK_PROVIDER_BIN",
    path: invalidOverride
  )) {
    try resolver.resolveExecutableURL()
  }
}

@Test
func externalProviderResolverUsesLoginShellBeforeStandardPaths() throws {
  let fixture = try ExternalProviderCLIResolverFixture()
  defer { fixture.remove() }
  let shellURL = try fixture.makeExecutable("bin/zsh")
  let shellResult = try fixture.makeExecutable("shell/provider")
  let standardURL = try fixture.makeExecutable("opt/homebrew/bin/provider")

  let resolver = ExternalProviderCLIResolver(
    executableName: "provider",
    overrideEnvironmentKey: "PORTDECK_PROVIDER_BIN",
    environment: ["SHELL": shellURL.path],
    executableSearchPaths: [standardURL.path],
    loginShellLookup: { shell, executableName in
      #expect(shell == shellURL)
      #expect(executableName == "provider")
      return shellResult.path
    }
  )

  #expect(try resolver.resolveExecutableURL() == shellResult.standardizedFileURL)
}

@Test
func externalProviderResolverUsesStandardPathsAndNeverSearchesProjectDependencies() throws {
  let fixture = try ExternalProviderCLIResolverFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("monitored-project/node_modules/.bin/provider")
  let standardURL = try fixture.makeExecutable("usr/local/bin/provider")

  let resolver = ExternalProviderCLIResolver(
    executableName: "provider",
    overrideEnvironmentKey: "PORTDECK_PROVIDER_BIN",
    environment: ["SHELL": fixture.root.appendingPathComponent("missing-shell").path],
    executableSearchPaths: [standardURL.path],
    loginShellLookup: { _, _ in
      Issue.record("Login-shell lookup should not run for a missing shell.")
      return nil
    }
  )

  #expect(try resolver.resolveExecutableURL() == standardURL.standardizedFileURL)
}

@Test
func externalProviderResolverReturnsNilWhenCLIIsMissing() throws {
  let fixture = try ExternalProviderCLIResolverFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("monitored-project/node_modules/.bin/provider")

  let resolver = ExternalProviderCLIResolver(
    executableName: "provider",
    overrideEnvironmentKey: "PORTDECK_PROVIDER_BIN",
    environment: [:],
    executableSearchPaths: []
  )

  #expect(try resolver.resolveExecutableURL() == nil)
}

@Test(arguments: [
  (ConvexRuntimeResolver.supportedVersionRange, "1.42.1", "1.99.99", "2.0.0"),
  (SupabaseRuntimeResolver.supportedVersionRange, "2.109.1", "2.999.999", "3.0.0"),
  (CloudflareRuntimeResolver.supportedVersionRange, "4.111.0", "4.999.999", "5.0.0"),
  (RailwayRuntimeResolver.supportedVersionRange, "5.26.2", "5.999.999", "6.0.0"),
  (FlyRuntimeResolver.supportedVersionRange, "0.4.71", "0.4.999", "0.5.0"),
  (NetlifyRuntimeResolver.supportedVersionRange, "26.2.0", "26.999.999", "27.0.0")
])
func providerVersionRangesAreInclusiveAtMinimumAndExclusiveAtNextMajor(
  range: SupportedProviderCLIVersionRange,
  minimum: String,
  laterSupported: String,
  maximum: String
) {
  #expect(range.contains(ProviderCLIVersion(string: minimum)!))
  #expect(range.contains(ProviderCLIVersion(string: laterSupported)!))
  #expect(!range.contains(ProviderCLIVersion(string: maximum)!))
}

@Test
func providerExecutionEnvironmentPrependsResolvedExecutableDirectory() {
  let environment = ProviderCLIExecutionEnvironment.make(
    executableURL: URL(fileURLWithPath: "/custom/bin/provider"),
    base: ["PATH": "/usr/bin:/custom/bin"]
  )
  #expect(environment["PATH"] == "/custom/bin:/usr/bin")
}

private final class ExternalProviderCLIResolverFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("portdeck-external-cli-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
