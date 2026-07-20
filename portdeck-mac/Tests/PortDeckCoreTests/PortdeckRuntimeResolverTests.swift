import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesPortdeckRuntimeByOverrideThenBundleThenSource() throws {
  let fixture = try PortdeckRuntimeFixture()
  defer { fixture.remove() }

  let overrideCLI = try fixture.makeFile("override/portdeck-cli.js")
  let overrideNode = try fixture.makeExecutable("override/node")
  let bundledCLI = try fixture.makeFile("PortDeck.app/Contents/Resources/PortDeckRuntime/portdeck-cli.js")
  let bundledNode = try fixture.makeExecutable("PortDeck.app/Contents/Resources/PortDeckRuntime/bin/node")
  let sourceCLI = try fixture.makeFile("workspace/portdeck-app/dist/cli.js")
  let sourceNode = try fixture.makeExecutable("system/node")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let developmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")

  let overrideResolver = PortdeckRuntimeResolver(
    environment: [
      PortdeckRuntimeResolver.cliOverrideEnvironmentKey: overrideCLI.path,
      PortdeckRuntimeResolver.nodeOverrideEnvironmentKey: overrideNode.path
    ],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(try overrideResolver.resolveRuntime() == PortdeckRuntime(nodeURL: overrideNode, cliURL: overrideCLI))

  let bundleResolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(try bundleResolver.resolveRuntime() == PortdeckRuntime(nodeURL: bundledNode, cliURL: bundledCLI))

  try FileManager.default.removeItem(
    at: resourceURL.appendingPathComponent(PortdeckRuntimeResolver.packagedRuntimeRelativePath)
  )
  let packagedResolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(throws: PortdeckRuntimeResolverError.incompletePackagedRuntime(
    component: "helper",
    path: resourceURL.appendingPathComponent("PortDeckRuntime/portdeck-cli.js").path
  )) {
    try packagedResolver.resolveRuntime()
  }

  _ = try fixture.makeFile("PortDeck.app/Contents/Resources/.portdeck-source-development")
  let sourceResolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(try sourceResolver.resolveRuntime() == PortdeckRuntime(nodeURL: sourceNode, cliURL: sourceCLI))
}

@Test func validPortdeckOverridesCanReplaceIndividualPackagedComponents() throws {
  let fixture = try PortdeckRuntimeFixture()
  defer { fixture.remove() }

  let overrideCLI = try fixture.makeFile("override/portdeck-cli.js")
  let bundledCLI = try fixture.makeFile("PortDeck.app/Contents/Resources/PortDeckRuntime/portdeck-cli.js")
  let bundledNode = try fixture.makeExecutable("PortDeck.app/Contents/Resources/PortDeckRuntime/bin/node")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")

  let resolver = PortdeckRuntimeResolver(
    environment: [PortdeckRuntimeResolver.cliOverrideEnvironmentKey: overrideCLI.path],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [],
    systemNodeSearchPaths: []
  )
  #expect(try resolver.resolveRuntime() == PortdeckRuntime(nodeURL: bundledNode, cliURL: overrideCLI))
  #expect(bundledCLI.path != overrideCLI.path)
}

@Test func invalidPortdeckOverridesNeverFallThrough() throws {
  let fixture = try PortdeckRuntimeFixture()
  defer { fixture.remove() }

  let sourceCLI = try fixture.makeFile("workspace/portdeck-app/dist/cli.js")
  let sourceNode = try fixture.makeExecutable("system/node")
  let developmentRoot = fixture.root.appendingPathComponent("workspace/portdeck-mac/.build")
  let missingCLI = fixture.root.appendingPathComponent("missing-cli").path
  let missingNode = fixture.root.appendingPathComponent("missing-node").path

  let invalidCLIResolver = PortdeckRuntimeResolver(
    environment: [PortdeckRuntimeResolver.cliOverrideEnvironmentKey: missingCLI],
    bundleResourceURL: nil,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(throws: PortdeckRuntimeResolverError.invalidOverride(
    variable: PortdeckRuntimeResolver.cliOverrideEnvironmentKey,
    path: missingCLI
  )) {
    try invalidCLIResolver.resolveRuntime()
  }

  let invalidNodeResolver = PortdeckRuntimeResolver(
    environment: [PortdeckRuntimeResolver.nodeOverrideEnvironmentKey: missingNode],
    bundleResourceURL: nil,
    developmentSearchRoots: [developmentRoot],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(throws: PortdeckRuntimeResolverError.invalidOverride(
    variable: PortdeckRuntimeResolver.nodeOverrideEnvironmentKey,
    path: missingNode
  )) {
    try invalidNodeResolver.resolveRuntime()
  }
  #expect(FileManager.default.fileExists(atPath: sourceCLI.path))
}

@Test func partialPackagedPortdeckRuntimeNeverFallsThroughToSource() throws {
  let fixture = try PortdeckRuntimeFixture()
  defer { fixture.remove() }

  _ = try fixture.makeFile("PortDeck.app/Contents/Resources/PortDeckRuntime/portdeck-cli.js")
  _ = try fixture.makeFile("workspace/portdeck-app/dist/cli.js")
  let sourceNode = try fixture.makeExecutable("system/node")
  let resourceURL = fixture.root.appendingPathComponent("PortDeck.app/Contents/Resources")
  let expectedNodePath = resourceURL.appendingPathComponent("PortDeckRuntime/bin/node").path

  let resolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: resourceURL,
    developmentSearchRoots: [fixture.root.appendingPathComponent("workspace")],
    systemNodeSearchPaths: [sourceNode.path]
  )
  #expect(throws: PortdeckRuntimeResolverError.incompletePackagedRuntime(
    component: "Node runtime",
    path: expectedNodePath
  )) {
    try resolver.resolveRuntime()
  }
}

@Test func reportsMissingSourcePortdeckComponentsClearly() throws {
  let fixture = try PortdeckRuntimeFixture()
  defer { fixture.remove() }

  let missingCLIResolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root],
    systemNodeSearchPaths: []
  )
  #expect(throws: PortdeckRuntimeResolverError.missingCLI) {
    try missingCLIResolver.resolveRuntime()
  }

  _ = try fixture.makeFile("portdeck-app/dist/cli.js")
  let missingNodeResolver = PortdeckRuntimeResolver(
    environment: [:],
    bundleResourceURL: nil,
    developmentSearchRoots: [fixture.root],
    systemNodeSearchPaths: []
  )
  #expect(throws: PortdeckRuntimeResolverError.missingNode) {
    try missingNodeResolver.resolveRuntime()
  }
}

private struct PortdeckRuntimeFixture {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("portdeck-runtime-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func makeFile(_ relativePath: String) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data("fixture\n".utf8))
    return url
  }

  func makeExecutable(_ relativePath: String) throws -> URL {
    let url = try makeFile(relativePath)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
