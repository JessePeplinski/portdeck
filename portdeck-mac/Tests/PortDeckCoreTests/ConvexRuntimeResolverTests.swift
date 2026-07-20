import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesConvexRuntimeByOverrideThenBundleThenDevelopment() throws {
  let fixture = try ConvexRuntimeFixture()
  defer { fixture.remove() }

  let overrideURL = try fixture.makeExecutable("override/convex")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/convex/bin/convex")
  let developmentURL = try fixture.makeExecutable("workspace/node_modules/.bin/convex")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let nestedDevelopmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")

  let overrideResolver = ConvexRuntimeResolver(
    environment: [ConvexRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try overrideResolver.resolveExecutableURL() == overrideURL)

  let bundleResolver = ConvexRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try bundleResolver.resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  let packagedResolver = ConvexRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(throws: ConvexCLIError.missingRuntime) {
    try packagedResolver.resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  let developmentResolver = ConvexRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try developmentResolver.resolveExecutableURL() == developmentURL)
}

@Test func explicitConvexRuntimeOverrideDoesNotSilentlyFallBack() throws {
  let fixture = try ConvexRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/node_modules/.bin/convex")

  let resolver = ConvexRuntimeResolver(
    environment: [ConvexRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace")]
  )
  #expect(throws: ConvexCLIError.missingRuntime) {
    try resolver.resolveExecutableURL()
  }
}

@Test func reportsUnavailableWhenNoManagedConvexRuntimeExists() throws {
  let fixture = try ConvexRuntimeFixture()
  defer { fixture.remove() }
  let resolver = ConvexRuntimeResolver(
    environment: [:],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root]
  )
  #expect(throws: ConvexCLIError.missingRuntime) {
    try resolver.resolveExecutableURL()
  }
}

private struct ConvexRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("portdeck-convex-runtime-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
