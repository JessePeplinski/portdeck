import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesFlyRuntimeByOverrideThenBundleThenPortDeckDevelopmentStaging() throws {
  let fixture = try FlyRuntimeFixture()
  defer { fixture.remove() }
  let overrideURL = try fixture.makeExecutable("override/flyctl")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/fly/bin/flyctl")
  let developmentURL = try fixture.makeExecutable("workspace/portdeck-mac/.build/provider-runtimes/fly/bin/flyctl")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let developmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build/debug")

  #expect(try FlyRuntimeResolver(
    environment: [FlyRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == overrideURL)

  #expect(try FlyRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  #expect(throws: FlyCLIError.missingRuntime) {
    try FlyRuntimeResolver(
      environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
    ).resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  #expect(try FlyRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == developmentURL)
}

@Test func authoritativeFlyOverrideDoesNotFallThroughOrSearchPath() throws {
  let fixture = try FlyRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/portdeck-mac/.build/provider-runtimes/fly/bin/flyctl")
  _ = try fixture.makeExecutable("path/flyctl")

  let resolver = FlyRuntimeResolver(
    environment: [
      FlyRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path,
      "PATH": fixture.root.appendingPathComponent("path").path
    ],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace/portdeck-mac")]
  )
  #expect(throws: FlyCLIError.missingRuntime) { try resolver.resolveExecutableURL() }
}

private struct FlyRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-fly-runtime-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
