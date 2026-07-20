import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesNetlifyRuntimeByOverrideThenBundleThenRootDependency() throws {
  let fixture = try NetlifyRuntimeFixture()
  defer { fixture.remove() }
  let overrideURL = try fixture.makeExecutable("override/netlify")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/netlify/bin/netlify")
  let dependencyURL = try fixture.makeExecutable("workspace/node_modules/.bin/netlify")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let developmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build/debug")

  #expect(try NetlifyRuntimeResolver(
    environment: [NetlifyRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == overrideURL)

  #expect(try NetlifyRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  #expect(throws: NetlifyCLIError.missingRuntime) {
    try NetlifyRuntimeResolver(
      environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
    ).resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  #expect(try NetlifyRuntimeResolver(
    environment: [:], bundleResourceURL: resourceURL, developmentSearchRoots: [developmentRoot]
  ).resolveExecutableURL() == dependencyURL)
}

@Test func authoritativeNetlifyOverrideDoesNotFallThroughOrSearchPathProjectsOrHomebrew() throws {
  let fixture = try NetlifyRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/node_modules/.bin/netlify")
  _ = try fixture.makeExecutable("path/netlify")
  _ = try fixture.makeExecutable("opt/homebrew/bin/netlify")
  _ = try fixture.makeExecutable("monitored-project/node_modules/.bin/netlify")

  let resolver = NetlifyRuntimeResolver(
    environment: [
      NetlifyRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path,
      "PATH": fixture.root.appendingPathComponent("path").path
    ],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace/portdeck-mac")]
  )
  #expect(throws: NetlifyCLIError.missingRuntime) { try resolver.resolveExecutableURL() }
}

private struct NetlifyRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-netlify-runtime-tests-\(UUID().uuidString)")
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
