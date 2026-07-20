import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesSupabaseRuntimeByOverrideThenBundleThenDevelopment() throws {
  let fixture = try SupabaseRuntimeFixture()
  defer { fixture.remove() }

  let overrideURL = try fixture.makeExecutable("override/supabase")
  let bundledURL = try fixture.makeExecutable("PortDeck.app/Contents/Resources/ProviderRuntimes/supabase/bin/supabase")
  let developmentURL = try fixture.makeExecutable("workspace/node_modules/.bin/supabase")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let nestedDevelopmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")

  let overrideResolver = SupabaseRuntimeResolver(
    environment: [SupabaseRuntimeResolver.overrideEnvironmentKey: overrideURL.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try overrideResolver.resolveExecutableURL() == overrideURL)

  let bundleResolver = SupabaseRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try bundleResolver.resolveExecutableURL() == bundledURL)

  try FileManager.default.removeItem(at: bundledURL)
  let packagedResolver = SupabaseRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(throws: SupabaseCLIError.missingRuntime) {
    try packagedResolver.resolveExecutableURL()
  }

  _ = try fixture.makeExecutable("PortDeck.app/Contents/Resources/.portdeck-source-development")
  let developmentResolver = SupabaseRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [nestedDevelopmentRoot]
  )
  #expect(try developmentResolver.resolveExecutableURL() == developmentURL)
}

@Test func explicitSupabaseRuntimeOverrideDoesNotSilentlyFallBack() throws {
  let fixture = try SupabaseRuntimeFixture()
  defer { fixture.remove() }
  _ = try fixture.makeExecutable("workspace/node_modules/.bin/supabase")

  let resolver = SupabaseRuntimeResolver(
    environment: [SupabaseRuntimeResolver.overrideEnvironmentKey: fixture.root.appendingPathComponent("missing").path],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace")]
  )
  #expect(throws: SupabaseCLIError.missingRuntime) {
    try resolver.resolveExecutableURL()
  }
}

@Test func reportsUnavailableWhenNoManagedSupabaseRuntimeExists() throws {
  let fixture = try SupabaseRuntimeFixture()
  defer { fixture.remove() }
  let resolver = SupabaseRuntimeResolver(
    environment: [:],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root]
  )
  #expect(throws: SupabaseCLIError.missingRuntime) {
    try resolver.resolveExecutableURL()
  }
}

private struct SupabaseRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("portdeck-supabase-runtime-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
