import Foundation

public protocol ConvexProjectCandidateResolving: Sendable {
  func resolve(from status: PortdeckStatus?) -> [ConvexProjectCandidate]
}

public struct ConvexProjectCandidateResolver: ConvexProjectCandidateResolving, Sendable {
  public init() {}

  public func resolve(from status: PortdeckStatus?) -> [ConvexProjectCandidate] {
    guard let status else {
      return []
    }

    var candidatesByPath: [String: ConvexProjectCandidate] = [:]
    for group in status.groups {
      let worktreesWithPaths = group.worktrees.compactMap { worktree -> (WorktreeGroup, String)? in
        guard let path = worktree.path else { return nil }
        return (worktree, standardized(path))
      }

      if worktreesWithPaths.isEmpty, let repoRoot = group.repoRoot {
        addCandidate(
          seededAt: standardized(repoRoot),
          boundary: standardized(repoRoot),
          projectName: group.projectName,
          into: &candidatesByPath
        )
      }

      for (worktree, worktreePath) in worktreesWithPaths {
        addCandidate(
          seededAt: worktreePath,
          boundary: worktreePath,
          projectName: group.projectName,
          into: &candidatesByPath
        )

        for service in worktree.services {
          if let subcontext = service.subcontext {
            addCandidate(
              seededAt: standardized(subcontext.path),
              boundary: worktreePath,
              projectName: group.projectName,
              into: &candidatesByPath
            )
          }
        }
      }
    }

    return candidatesByPath.values.sorted {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
  }

  private func addCandidate(
    seededAt seedPath: String,
    boundary: String,
    projectName: String,
    into candidates: inout [String: ConvexProjectCandidate]
  ) {
    guard isPath(seedPath, within: boundary),
      let package = nearestConvexPackage(from: seedPath, through: boundary)
    else {
      return
    }

    candidates[package.path] = ConvexProjectCandidate(
      projectName: projectName,
      packageName: package.name,
      packagePath: package.path
    )
  }

  private func nearestConvexPackage(from seedPath: String, through boundary: String) -> (path: String, name: String?)? {
    var current = seedPath
    while isPath(current, within: boundary) {
      let manifestURL = URL(fileURLWithPath: current).appendingPathComponent("package.json")
      if let data = try? Data(contentsOf: manifestURL),
        let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data),
        manifest.hasConvexDependency
      {
        return (current, manifest.name)
      }

      if current == boundary {
        break
      }
      let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
      if parent == current {
        break
      }
      current = parent
    }
    return nil
  }

  private func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func isPath(_ path: String, within boundary: String) -> Bool {
    path == boundary || path.hasPrefix(boundary.hasSuffix("/") ? boundary : boundary + "/")
  }
}

private struct PackageManifest: Decodable {
  let name: String?
  let dependencies: [String: String]?
  let devDependencies: [String: String]?
  let optionalDependencies: [String: String]?

  var hasConvexDependency: Bool {
    dependencies?["convex"] != nil || devDependencies?["convex"] != nil || optionalDependencies?["convex"] != nil
  }
}
