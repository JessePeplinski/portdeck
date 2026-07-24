import Foundation
import Testing
@testable import PortDeckCore

@Test func resolvesActiveConvexPackagesFromWorktreesAndSubcontextsWithoutDuplicates() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let app = root.appendingPathComponent("apps/web")
  let plain = root.appendingPathComponent("packages/plain")
  try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try writePackage(at: root, name: "workspace", convex: true)
  try writePackage(at: app, name: "web-app", convex: true)
  try writePackage(at: plain, name: "plain", convex: false)

  let status = try decodedStatus(
    projectName: "Workspace",
    repoRoot: root.path,
    worktreePath: root.path,
    subcontextPaths: [app.path, app.path, plain.path]
  )
  let candidates = ConvexProjectCandidateResolver().resolve(from: status)

  #expect(Set(candidates.map(\.packagePath)) == Set([root.path, app.path]))
  #expect(candidates.first { $0.packagePath == app.path }?.displayName == "Workspace / web-app")
}

@Test func usesRepoRootOnlyWhenNoActiveWorktreePathExistsAndSkipsNonConvexPackages() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  try writePackage(at: root, name: "fallback", convex: true)
  let fallback = try decodedStatus(projectName: "Fallback", repoRoot: root.path, worktreePath: nil, subcontextPaths: [])
  #expect(ConvexProjectCandidateResolver().resolve(from: fallback).map(\.packagePath) == [root.path])

  try writePackage(at: root, name: "fallback", convex: false)
  #expect(ConvexProjectCandidateResolver().resolve(from: fallback).isEmpty)
}

private func writePackage(at url: URL, name: String, convex: Bool) throws {
  let dependency = convex ? #", "dependencies": { "convex": "^1.42.1" }"# : ""
  let json = #"{ "name": "\#(name)"\#(dependency) }"#
  try Data(json.utf8).write(to: url.appendingPathComponent("package.json"))
}

private func decodedStatus(
  projectName: String,
  repoRoot: String,
  worktreePath: String?,
  subcontextPaths: [String]
) throws -> PortdeckStatus {
  let services = subcontextPaths.enumerated().map { index, path in
    """
    {
      "id": "service-\(index)",
      "name": "service-\(index)",
      "source": "process",
      "status": "running",
      "confidence": "high",
      "subcontext": {
        "type": "package",
        "name": "package-\(index)",
        "displayName": "package-\(index)",
        "path": \(jsonString(path)),
        "relativePath": ".",
        "manifestPath": \(jsonString(path + "/package.json"))
      }
    }
    """
  }.joined(separator: ",")
  let worktree = worktreePath.map { path in
    """
    {
      "name": "main",
      "path": \(jsonString(path)),
      "branch": "main",
      "services": [\(services)]
    }
    """
  }
  let json = """
  {
    "schemaVersion": "0.2",
    "generatedAt": "2026-07-10T12:00:00Z",
    "groups": [{
      "projectName": \(jsonString(projectName)),
      "repoRoot": \(jsonString(repoRoot)),
      "worktrees": [\(worktree ?? "")]
    }],
    "unknown": [],
    "warnings": []
  }
  """
  return try JSONDecoder().decode(PortdeckStatus.self, from: Data(json.utf8))
}

private func jsonString(_ value: String) -> String {
  let data = try! JSONEncoder().encode(value)
  return String(data: data, encoding: .utf8)!
}
