import Foundation
import Testing
@testable import PortDeckCore

@Test func discoversJSONJSONCAndTOMLWorkersWithoutDecodingNestedConfiguration() throws {
  let root = try makeCloudflareCandidateRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let json = root.appendingPathComponent("apps/json")
  let jsonc = root.appendingPathComponent("apps/jsonc")
  let toml = root.appendingPathComponent("apps/toml")
  for url in [json, jsonc, toml] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

  try Data(#"{"name":"json-worker","account_id":"account-a","vars":{"SECRET":"ignored"}}"#.utf8)
    .write(to: json.appendingPathComponent("wrangler.json"))
  try Data("""
  {
    // Only top-level identity is decoded.
    "name": "jsonc-worker",
    "account_id": "account-b",
    "bindings": [{ "name": "ignored" }],
  }
  """.utf8).write(to: jsonc.appendingPathComponent("wrangler.jsonc"))
  try Data("""
  name = "toml-worker"
  account_id = "account-c" # scoped account
  [vars]
  SECRET = "ignored"
  """.utf8).write(to: toml.appendingPathComponent("wrangler.toml"))

  let status = try candidateStatus(root: root, subcontexts: [json, jsonc, toml])
  let candidates = CloudflareProjectCandidateResolver().resolve(from: status)

  #expect(Set(candidates.map(\.name)) == ["json-worker", "jsonc-worker", "toml-worker"])
  #expect(Set(candidates.compactMap(\.accountID)) == ["account-a", "account-b", "account-c"])
}

@Test func resolvesParentWranglerConfigFromDependencyPackageAndDeduplicatesWorktrees() throws {
  let root = try makeCloudflareCandidateRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let package = root.appendingPathComponent("apps/web")
  try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
  try Data(#"{"devDependencies":{"wrangler":"4.111.0"},"scripts":{"deploy":"ignored"}}"#.utf8)
    .write(to: package.appendingPathComponent("package.json"))
  try Data(#"{"name":"parent-worker"}"#.utf8).write(to: root.appendingPathComponent("wrangler.json"))

  let status = try candidateStatus(root: root, subcontexts: [package, package], projectName: "PortDeck")
  let candidates = CloudflareProjectCandidateResolver().resolve(from: status)

  #expect(candidates.count == 1)
  #expect(candidates[0].name == "parent-worker")
  #expect(candidates[0].associatedProjectNames == ["PortDeck"])
  #expect(candidates[0].configurationPath == root.appendingPathComponent("wrangler.json").path)
}

private func makeCloudflareCandidateRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("portdeck-cloudflare-candidates-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func candidateStatus(
  root: URL,
  subcontexts: [URL],
  projectName: String = "Workspace"
) throws -> PortdeckStatus {
  let services = subcontexts.enumerated().map { index, url in
    """
    {"id":"service-\(index)","name":"service-\(index)","source":"process","status":"running","confidence":"high","subcontext":{"type":"package","name":"package-\(index)","displayName":"package-\(index)","path":\(jsonString(url.path)),"relativePath":".","manifestPath":\(jsonString(url.appendingPathComponent("package.json").path))}}
    """
  }.joined(separator: ",")
  let json = """
  {"schemaVersion":"0.2","generatedAt":"2026-07-16T12:00:00Z","groups":[{"projectName":\(jsonString(projectName)),"repoRoot":\(jsonString(root.path)),"worktrees":[{"name":"main","path":\(jsonString(root.path)),"branch":"main","services":[\(services)]}]}],"unknown":[],"warnings":[]}
  """
  return try JSONDecoder().decode(PortdeckStatus.self, from: Data(json.utf8))
}

private func jsonString(_ value: String) -> String {
  String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
}
