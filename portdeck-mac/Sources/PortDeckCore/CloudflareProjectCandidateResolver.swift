import Foundation

public protocol CloudflareProjectCandidateResolving: Sendable {
  func resolve(from status: PortdeckStatus?) -> [CloudflareWorkerCandidate]
}

public struct CloudflareProjectCandidateResolver: CloudflareProjectCandidateResolving, Sendable {
  private static let configurationNames = ["wrangler.json", "wrangler.jsonc", "wrangler.toml"]

  public init() {}

  public func resolve(from status: PortdeckStatus?) -> [CloudflareWorkerCandidate] {
    guard let status else { return [] }
    var candidates: [String: CandidateAccumulator] = [:]

    for group in status.groups {
      let worktrees = group.worktrees.compactMap { worktree -> (path: String, seeds: [String])? in
        guard let path = worktree.path else { return nil }
        return (
          standardized(path),
          [path] + worktree.services.compactMap { $0.subcontext?.path }
        )
      }

      if worktrees.isEmpty, let repoRoot = group.repoRoot {
        inspect(seed: repoRoot, boundary: repoRoot, projectName: group.projectName, candidates: &candidates)
      }

      for worktree in worktrees {
        for seed in worktree.seeds {
          inspect(seed: seed, boundary: worktree.path, projectName: group.projectName, candidates: &candidates)
        }
      }
    }

    return candidates.values.map { accumulator in
      CloudflareWorkerCandidate(
        name: accumulator.name,
        accountID: accumulator.accountID,
        associatedProjectNames: Array(accumulator.projectNames),
        configurationPath: accumulator.configurationPath
      )
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private func inspect(
    seed: String,
    boundary: String,
    projectName: String,
    candidates: inout [String: CandidateAccumulator]
  ) {
    var current = standardized(seed)
    let boundary = standardized(boundary)
    guard isPath(current, within: boundary) else { return }

    while isPath(current, within: boundary) {
      _ = hasWranglerDependency(at: current)
      if let parsed = parseConfiguration(in: current) {
        let key = "\(parsed.accountID ?? "unscoped")|\(parsed.name)"
        if var existing = candidates[key] {
          existing.projectNames.insert(projectName)
          candidates[key] = existing
        } else {
          candidates[key] = CandidateAccumulator(
            name: parsed.name,
            accountID: parsed.accountID,
            configurationPath: parsed.path,
            projectNames: [projectName]
          )
        }
      }

      if current == boundary { break }
      let parent = URL(fileURLWithPath: current).deletingLastPathComponent().standardizedFileURL.path
      if parent == current { break }
      current = parent
    }
  }

  private func parseConfiguration(in directory: String) -> ParsedConfiguration? {
    for name in Self.configurationNames {
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
      guard FileManager.default.isReadableFile(atPath: url.path), let data = try? Data(contentsOf: url) else { continue }
      let values: MinimalConfiguration?
      if name == "wrangler.toml" {
        values = parseTOML(data)
      } else if name == "wrangler.jsonc" {
        values = parseJSON(removeJSONCommentsAndTrailingCommas(data))
      } else {
        values = parseJSON(data)
      }
      if let values, let workerName = normalized(values.name) {
        return ParsedConfiguration(
          name: workerName,
          accountID: normalized(values.accountID),
          path: url.path
        )
      }
    }
    return nil
  }

  private func parseJSON(_ data: Data) -> MinimalConfiguration? {
    try? JSONDecoder().decode(MinimalConfiguration.self, from: data)
  }

  private func parseTOML(_ data: Data) -> MinimalConfiguration? {
    guard let source = String(data: data, encoding: .utf8) else { return nil }
    var name: String?
    var accountID: String?
    for rawLine in source.split(whereSeparator: \Character.isNewline) {
      let line = stripTOMLComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") { break }
      guard let separator = line.firstIndex(of: "=") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if key == "name" { name = unquote(value) }
      if key == "account_id" { accountID = unquote(value) }
    }
    guard name != nil else { return nil }
    return MinimalConfiguration(name: name, accountID: accountID)
  }

  private func removeJSONCommentsAndTrailingCommas(_ data: Data) -> Data {
    guard let source = String(data: data, encoding: .utf8) else { return data }
    var output = ""
    var index = source.startIndex
    var inString = false
    var escaped = false
    var lineComment = false
    var blockComment = false

    while index < source.endIndex {
      let character = source[index]
      let next = source.index(after: index)
      let nextCharacter = next < source.endIndex ? source[next] : nil

      if lineComment {
        if character.isNewline { lineComment = false; output.append(character) }
      } else if blockComment {
        if character == "*" && nextCharacter == "/" { blockComment = false; index = next }
      } else if inString {
        output.append(character)
        if escaped { escaped = false }
        else if character == "\\" { escaped = true }
        else if character == "\"" { inString = false }
      } else if character == "\"" {
        inString = true
        output.append(character)
      } else if character == "/" && nextCharacter == "/" {
        lineComment = true
        index = next
      } else if character == "/" && nextCharacter == "*" {
        blockComment = true
        index = next
      } else {
        output.append(character)
      }
      index = source.index(after: index)
    }

    let pattern = #",\s*([}\]])"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return Data(output.utf8) }
    let range = NSRange(output.startIndex..., in: output)
    return Data(expression.stringByReplacingMatches(in: output, range: range, withTemplate: "$1").utf8)
  }

  private func hasWranglerDependency(at directory: String) -> Bool {
    let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: url),
      let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data)
    else { return false }
    return manifest.dependencies?["wrangler"] != nil
      || manifest.devDependencies?["wrangler"] != nil
      || manifest.optionalDependencies?["wrangler"] != nil
  }

  private func stripTOMLComment(_ line: String) -> String {
    var quote: Character?
    var escaped = false
    for index in line.indices {
      let character = line[index]
      if escaped { escaped = false; continue }
      if character == "\\" && quote == "\"" { escaped = true; continue }
      if character == "\"" || character == "'" {
        quote = quote == nil ? character : (quote == character ? nil : quote)
      } else if character == "#" && quote == nil {
        return String(line[..<index])
      }
    }
    return line
  }

  private func unquote(_ value: String) -> String? {
    guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else { return nil }
    return String(value.dropFirst().dropLast())
  }

  private func normalized(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  private func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func isPath(_ path: String, within boundary: String) -> Bool {
    path == boundary || path.hasPrefix(boundary.hasSuffix("/") ? boundary : boundary + "/")
  }
}

private struct MinimalConfiguration: Decodable {
  let name: String?
  let accountID: String?

  enum CodingKeys: String, CodingKey {
    case name
    case accountID = "account_id"
  }
}

private struct PackageManifest: Decodable {
  let dependencies: [String: String]?
  let devDependencies: [String: String]?
  let optionalDependencies: [String: String]?
}

private struct ParsedConfiguration {
  let name: String
  let accountID: String?
  let path: String
}

private struct CandidateAccumulator {
  let name: String
  let accountID: String?
  let configurationPath: String
  var projectNames: Set<String>
}
