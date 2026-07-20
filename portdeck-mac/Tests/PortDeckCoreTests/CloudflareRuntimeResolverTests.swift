import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesWranglerRuntimeByOverrideThenBundleThenDevelopment() throws {
  let fixture = try CloudflareRuntimeFixture()
  defer { fixture.remove() }

  let overrideURL = try fixture.makeExecutable("override/wrangler")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/cloudflare/bin/wrangler")
  let developmentURL = try fixture.makeExecutable("workspace/node_modules/.bin/wrangler")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let nestedDevelopmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")

  #expect(try CloudflareRuntimeResolver(
    environment: [CloudflareRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  ).resolveExecutableURL() == overrideURL)

  #expect(try CloudflareRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  ).resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  #expect(throws: CloudflareCLIError.missingRuntime) {
    try CloudflareRuntimeResolver(
      environment: [:],
      bundleResourceURL: resourceURL,
      developmentSearchRoots: [nestedDevelopmentRoot]
    ).resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  #expect(try CloudflareRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  ).resolveExecutableURL() == developmentURL)
}

@Test func authoritativeWranglerOverrideDoesNotFallBack() throws {
  let fixture = try CloudflareRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/node_modules/.bin/wrangler")

  let resolver = CloudflareRuntimeResolver(
    environment: [CloudflareRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace")]
  )
  #expect(throws: CloudflareCLIError.missingRuntime) { try resolver.resolveExecutableURL() }
}

private struct CloudflareRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-cloudflare-runtime-tests-\(UUID().uuidString)")
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
