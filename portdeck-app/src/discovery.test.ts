import { describe, expect, test } from "vitest";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { normalizeGitHubRepositoryUrl, resolveGitRemoteMetadata, resolveGitWorktreeMetadata, resolvePackageContext } from "./discovery.js";

describe("resolveGitWorktreeMetadata", () => {
  test("uses the primary Git worktree as repo root for linked worktrees", () => {
    const output = [
      "worktree /Users/developer/git/acme-web",
      "HEAD abc123",
      "branch refs/heads/main",
      "",
      "worktree /Users/developer/git/acme-web-lab",
      "HEAD def456",
      "branch refs/heads/feature/lab-self-serve-orgs"
    ].join("\n");

    expect(
      resolveGitWorktreeMetadata(
        output,
        "/Users/developer/git/acme-web-lab",
        "/Users/developer/git/acme-web-lab",
        "feature/lab-self-serve-orgs"
      )
    ).toEqual({
      repoRoot: "/Users/developer/git/acme-web",
      worktreePath: "/Users/developer/git/acme-web-lab",
      worktreeName: "feature/lab-self-serve-orgs"
    });
  });

  test("falls back to the current root when worktree output is unavailable", () => {
    expect(resolveGitWorktreeMetadata("", "/repo/portdeck", "/repo/portdeck", "main")).toEqual({
      repoRoot: "/repo/portdeck",
      worktreePath: "/repo/portdeck",
      worktreeName: "main"
    });
  });
});

describe("resolveGitRemoteMetadata", () => {
  test("parses HTTPS GitHub remotes", () => {
    expect(resolveGitRemoteMetadata("https://github.com/acme-inc/portdeck.git")).toEqual({
      remoteUrl: "https://github.com/acme-inc/portdeck.git",
      repositoryUrl: "https://github.com/acme-inc/portdeck"
    });
  });

  test("omits credential-bearing remote URLs while preserving the normalized repository", () => {
    expect(resolveGitRemoteMetadata("https://developer:example-password@github.com/acme-inc/portdeck.git")).toEqual({
      repositoryUrl: "https://github.com/acme-inc/portdeck"
    });
  });

  test("parses SSH GitHub remotes", () => {
    expect(resolveGitRemoteMetadata("git@github.com:acme-inc/portdeck.git")).toEqual({
      remoteUrl: "git@github.com:acme-inc/portdeck.git",
      repositoryUrl: "https://github.com/acme-inc/portdeck"
    });
    expect(resolveGitRemoteMetadata("ssh://git@github.com/acme-inc/portdeck.git")).toEqual({
      remoteUrl: "ssh://git@github.com/acme-inc/portdeck.git",
      repositoryUrl: "https://github.com/acme-inc/portdeck"
    });
  });

  test("omits invalid missing or unsupported remotes", () => {
    expect(resolveGitRemoteMetadata(undefined)).toEqual({});
    expect(resolveGitRemoteMetadata("")).toEqual({});
    expect(resolveGitRemoteMetadata("https://gitlab.com/acme/app.git")).toEqual({});
    expect(resolveGitRemoteMetadata("not a remote")).toEqual({});
    expect(normalizeGitHubRepositoryUrl("https://github.com/acme/app/tree/main")).toBeUndefined();
  });
});

describe("resolvePackageContext", () => {
  test("uses the nearest package.json between cwd and worktree path", async () => {
    const repo = await mkdtemp(path.join(os.tmpdir(), "portdeck-package-context-"));
    await writeFile(path.join(repo, "package.json"), JSON.stringify({ name: "root-workspace" }));

    const packageDirectory = path.join(repo, "apps", "web");
    const serviceCwd = path.join(packageDirectory, "src");
    await mkdir(serviceCwd, { recursive: true });
    await writeFile(path.join(packageDirectory, "package.json"), JSON.stringify({ name: "@acme/web" }));

    await expect(resolvePackageContext(serviceCwd, repo)).resolves.toEqual({
      type: "package",
      name: "@acme/web",
      displayName: "@acme/web",
      path: packageDirectory,
      relativePath: "apps/web",
      manifestPath: path.join(packageDirectory, "package.json")
    });
  });
});
