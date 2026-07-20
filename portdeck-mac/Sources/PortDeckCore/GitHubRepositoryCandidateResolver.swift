import Foundation

public protocol GitHubRepositoryCandidateResolving: Sendable {
  func resolve(from status: PortdeckStatus?) -> [GitHubRepositoryCandidate]
}

public struct GitHubRepositoryCandidateResolver: GitHubRepositoryCandidateResolving, Sendable {
  public init() {}

  public func resolve(from status: PortdeckStatus?) -> [GitHubRepositoryCandidate] {
    guard let status else { return [] }

    var repositories: [String: RepositoryAccumulator] = [:]
    for group in status.groups {
      add(repositoryURL: group.repositoryUrl, projectName: group.projectName, to: &repositories)
      for worktree in group.worktrees {
        add(repositoryURL: worktree.repositoryUrl, projectName: group.projectName, to: &repositories)
      }
    }

    return repositories.values.map { repository in
      GitHubRepositoryCandidate(
        owner: repository.owner,
        repository: repository.repository,
        projectNames: Array(repository.projectNames)
      )
    }
    .sorted {
      $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
    }
  }

  public static func parseRepositoryURL(_ rawValue: String?) -> (owner: String, repository: String)? {
    guard let rawValue,
      let components = URLComponents(string: rawValue),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == "github.com",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil
    else {
      return nil
    }

    let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard parts.count == 2,
      !parts[0].isEmpty,
      !parts[1].isEmpty,
      !parts[1].lowercased().hasSuffix(".git")
    else {
      return nil
    }
    return (parts[0], parts[1])
  }

  private func add(
    repositoryURL: String?,
    projectName: String,
    to repositories: inout [String: RepositoryAccumulator]
  ) {
    guard let parsed = Self.parseRepositoryURL(repositoryURL) else { return }
    let key = "\(parsed.owner)/\(parsed.repository)".lowercased()
    if var existing = repositories[key] {
      existing.projectNames.insert(projectName)
      repositories[key] = existing
    } else {
      repositories[key] = RepositoryAccumulator(
        owner: parsed.owner,
        repository: parsed.repository,
        projectNames: [projectName]
      )
    }
  }
}

private struct RepositoryAccumulator {
  let owner: String
  let repository: String
  var projectNames: Set<String>
}
