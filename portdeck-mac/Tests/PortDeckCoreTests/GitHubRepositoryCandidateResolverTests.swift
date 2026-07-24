import Foundation
import Testing
@testable import PortDeckCore

@Test func parsesOnlyStrictGitHubRepositoryURLs() {
  #expect(GitHubRepositoryCandidateResolver.parseRepositoryURL("https://github.com/OpenAI/codex")?.owner == "OpenAI")
  #expect(GitHubRepositoryCandidateResolver.parseRepositoryURL("https://github.com/OpenAI/codex/")?.repository == "codex")

  let invalid = [
    "http://github.com/OpenAI/codex",
    "https://gitlab.com/OpenAI/codex",
    "https://github.com/OpenAI",
    "https://github.com/OpenAI/codex/extra",
    "https://github.com/OpenAI/codex.git",
    "https://github.com/OpenAI/codex?tab=actions",
    "https://user@github.com/OpenAI/codex",
    "git@github.com:OpenAI/codex.git"
  ]
  for value in invalid {
    #expect(GitHubRepositoryCandidateResolver.parseRepositoryURL(value) == nil)
  }
}

@Test func resolvesAndDeduplicatesActiveGitHubRepositoriesWithProjectNames() {
  let status = PortdeckStatus(
    schemaVersion: "0.2",
    generatedAt: "2026-07-16T12:00:00Z",
    groups: [
      ProjectGroup(
        projectName: "PortDeck",
        repoRoot: "/portdeck",
        repositoryUrl: "https://github.com/acme-inc/portdeck",
        worktrees: [
          WorktreeGroup(
            name: "main",
            path: "/portdeck",
            branch: "main",
            repositoryUrl: "https://github.com/ACME-INC/PORTDECK",
            services: []
          )
        ]
      ),
      ProjectGroup(
        projectName: "PortDeck Docs",
        repoRoot: "/docs",
        repositoryUrl: "https://github.com/acme-inc/portdeck",
        worktrees: []
      ),
      ProjectGroup(
        projectName: "Unsupported",
        repoRoot: "/unsupported",
        repositoryUrl: "https://gitlab.com/example/unsupported",
        worktrees: []
      )
    ],
    unknown: [],
    warnings: []
  )

  let candidates = GitHubRepositoryCandidateResolver().resolve(from: status)
  #expect(candidates.count == 1)
  #expect(candidates[0].fullName == "acme-inc/portdeck")
  #expect(candidates[0].projectNames == ["PortDeck", "PortDeck Docs"])
  #expect(candidates[0].displayProjectName == "PortDeck, PortDeck Docs")
}
