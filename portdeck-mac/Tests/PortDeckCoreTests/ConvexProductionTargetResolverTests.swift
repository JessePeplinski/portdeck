import Foundation
import Testing
@testable import PortDeckCore

@Test func matchesLinkedRepoNamesToExplicitConvexProductionTargets() {
  let acmeWeb = ConvexProjectCandidate(
    projectName: "acme-web",
    packageName: "launchloop",
    packagePath: "/repo/acme-web"
  )
  let shop = ConvexProjectCandidate(
    projectName: "sample-market",
    packageName: "sample-market",
    packagePath: "/repo/sample-market"
  )
  let webTarget = target(team: "example-team", project: "acme-web")
  let marketTarget = target(team: "sample-market", project: "sample-market")

  #expect(ConvexProductionTargetMatcher.matches(candidate: acmeWeb, target: webTarget))
  #expect(!ConvexProductionTargetMatcher.matches(candidate: acmeWeb, target: marketTarget))
  #expect(ConvexProductionTargetMatcher.matches(candidate: shop, target: marketTarget))
  #expect(webTarget.deploymentReference == "example-team:acme-web:prod")
  #expect(webTarget.dashboardURLString == "https://dashboard.convex.dev/d/production-deployment?view=insights")
}

@Test func usesTheExistingConvexTokenTransientlyWithoutCopyingOrExposingIt() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("portdeck-convex-token-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let configURL = directory.appendingPathComponent("config.json")
  let token = "transient-super-secret-token"
  try Data(#"{"accessToken":"transient-super-secret-token"}"#.utf8).write(to: configURL)
  let loader = FakeConvexHTTPDataLoader(responses: [
    .success(jsonResponse(#"[{"id":1}]"#)),
    .success(jsonResponse(#"[{"id":2,"name":"Demo","slug":"demo","teamSlug":"team"}]"#)),
    .success(jsonResponse(#"[{"name":"steady-otter-123","deploymentType":"prod","isDefault":true,"lastDeployTime":1750000000000}]"#))
  ])
  let resolver = ConvexManagementAPIProductionTargetResolver(configURL: configURL, loader: loader)
  let candidate = ConvexProjectCandidate(projectName: "Demo", packageName: nil, packagePath: "/repo/demo")

  let resolved = try await resolver.resolveProductionTarget(for: candidate)
  #expect(resolved.deploymentName == "steady-otter-123")
  #expect(await loader.requests.count == 3)
  #expect(await loader.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" })
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])

  let failingLoader = FakeConvexHTTPDataLoader(responses: [
    .success((Data("upstream leaked \(token)".utf8), httpResponse(status: 500)))
  ])
  let failingResolver = ConvexManagementAPIProductionTargetResolver(configURL: configURL, loader: failingLoader)
  do {
    _ = try await failingResolver.resolveProductionTarget(for: candidate)
    Issue.record("Expected Management API resolution to fail")
  } catch {
    #expect(!error.localizedDescription.contains(token))
  }
}

private func target(team: String, project: String) -> ConvexProductionTarget {
  ConvexProductionTarget(
    teamSlug: team,
    projectName: project,
    projectSlug: project,
    deploymentName: "production-deployment",
    lastDeployTime: Date(timeIntervalSince1970: 100)
  )
}

private actor FakeConvexHTTPDataLoader: ConvexHTTPDataLoading {
  private var responses: [Result<(Data, HTTPURLResponse), Error>]
  private(set) var requests: [URLRequest] = []

  init(responses: [Result<(Data, HTTPURLResponse), Error>]) {
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard !responses.isEmpty else { throw FakeConvexHTTPError.missingResponse }
    return try responses.removeFirst().get()
  }
}

private enum FakeConvexHTTPError: Error { case missingResponse }

private func jsonResponse(_ json: String) -> (Data, HTTPURLResponse) {
  (Data(json.utf8), httpResponse(status: 200))
}

private func httpResponse(status: Int) -> HTTPURLResponse {
  HTTPURLResponse(
    url: URL(string: "https://api.convex.dev/test")!,
    statusCode: status,
    httpVersion: nil,
    headerFields: ["Content-Type": "application/json"]
  )!
}
