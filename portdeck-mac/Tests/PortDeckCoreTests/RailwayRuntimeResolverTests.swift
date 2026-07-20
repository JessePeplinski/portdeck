import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesRailwayRuntimeByOverrideThenBundleThenDevelopment() throws {
  let fixture = try RailwayRuntimeFixture()
  defer { fixture.remove() }

  let overrideURL = try fixture.makeExecutable("override/railway")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/railway/bin/railway")
  let developmentURL = try fixture.makeExecutable("workspace/node_modules/.bin/railway")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let developmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")

  #expect(try RailwayRuntimeResolver(
    environment: [RailwayRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == overrideURL)

  #expect(try RailwayRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  #expect(throws: RailwayCLIError.missingRuntime) {
    try RailwayRuntimeResolver(
      environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
    ).resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  #expect(try RailwayRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == developmentURL)
}

@Test func authoritativeRailwayOverrideDoesNotFallThrough() throws {
  let fixture = try RailwayRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/node_modules/.bin/railway")

  let resolver = RailwayRuntimeResolver(
    environment: [RailwayRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace")]
  )
  #expect(throws: RailwayCLIError.missingRuntime) { try resolver.resolveExecutableURL() }
}

private struct RailwayRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-railway-runtime-tests-\(UUID().uuidString)")
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
