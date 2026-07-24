import AppKit
import Foundation
import PortDeckCore

@MainActor
final class StatusModel: ObservableObject {
  nonisolated static let refreshIntervalSeconds = 5
  private static let refreshInterval = Duration.seconds(refreshIntervalSeconds)
  private static let showLikelySystemListenersKey = "showLikelySystemListeners"

  @Published private(set) var status: PortdeckStatus?
  @Published private(set) var rawJSON = ""
  @Published private(set) var errorMessage: String?
  @Published private(set) var stopFailureMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isStopping = false
  @Published private(set) var stoppingServiceID: String?
  @Published private(set) var stoppingProjectID: String?
  @Published private(set) var activeSavedProjectID: String?
  @Published private(set) var projectActionResult: SavedProjectRunResult?
  @Published private(set) var projectConfigurationError: String?
  @Published private(set) var isManagingSavedProject = false
  @Published private(set) var lastUpdated: Date?
  @Published var showLikelySystemListeners: Bool {
    didSet {
      userDefaults.set(showLikelySystemListeners, forKey: Self.showLikelySystemListenersKey)
    }
  }

  private let userDefaults: UserDefaults
  private let loader: any PortdeckStatusLoading
  private let pollInterval: Duration
  private let now: @Sendable () -> Date
  private var stopTask: Task<Void, Never>?
  private var savedProjectTask: Task<Void, Never>?

  init(
    userDefaults: UserDefaults = .standard,
    loader: any PortdeckStatusLoading = LivePortdeckStatusLoader(),
    pollInterval: Duration = StatusModel.refreshInterval,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.userDefaults = userDefaults
    self.loader = loader
    self.pollInterval = pollInterval
    self.now = now
    showLikelySystemListeners = userDefaults.bool(forKey: Self.showLikelySystemListenersKey)
  }

  var showsHeaderProgress: Bool {
    PortdeckHeaderProgressState(isRefreshing: isRefreshing, isStopping: isStopping || isManagingSavedProject).showsProgress
  }

  func runAutoRefresh() async {
    await refresh()
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: pollInterval)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await refresh()
    }
  }

  func refresh() async {
    await refresh(force: false)
  }

  private func refresh(force: Bool) async {
    if isRefreshing || (!force && (isStopping || isManagingSavedProject)) {
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let loaded = try await loader.load()
      guard !Task.isCancelled else { return }
      status = LocalStatusPresentation.stabilized(loaded.status, preserving: status)
      rawJSON = loaded.rawJSON
      errorMessage = nil
      lastUpdated = now()
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = localStatusErrorMessage(error.localizedDescription)
    }
  }

  func requestStopService(_ service: PortdeckService) {
    guard service.canStop, stopTask == nil else {
      return
    }

    stoppingServiceID = service.id
    stopTask = Task { [weak self] in
      await self?.stopService(service)
    }
  }

  func requestStopAll(_ target: ProjectStopAllTarget) {
    guard !target.serviceIDs.isEmpty, stopTask == nil else {
      return
    }

    stoppingProjectID = target.projectID
    stopTask = Task { [weak self] in
      await self?.stopAll(target)
    }
  }

  func suggestions(forProjectPath path: String, serviceIDs: [String] = []) async throws -> SavedProjectSuggestionResult {
    try await loader.suggestProject(path: path, serviceIDs: serviceIDs)
  }

  func saveProject(_ draft: SavedProjectDraft) async -> Bool {
    guard !isManagingSavedProject else { return false }
    isManagingSavedProject = true
    projectConfigurationError = nil
    defer { isManagingSavedProject = false }
    do {
      try await loader.saveProject(draft)
      await refresh(force: true)
      return true
    } catch {
      projectConfigurationError = localStatusErrorMessage(error.localizedDescription)
      return false
    }
  }

  func removeProject(id projectId: String) async -> Bool {
    guard !isManagingSavedProject else { return false }
    isManagingSavedProject = true
    activeSavedProjectID = projectId
    projectConfigurationError = nil
    defer {
      isManagingSavedProject = false
      activeSavedProjectID = nil
    }
    do {
      try await loader.removeProject(id: projectId)
      await refresh(force: true)
      return true
    } catch {
      projectConfigurationError = localStatusErrorMessage(error.localizedDescription)
      return false
    }
  }

  func requestStartProject(_ project: SavedProjectStatus, port: Int? = nil) {
    guard savedProjectTask == nil else { return }
    beginSavedProjectAction(project.id) { [loader] in
      try await loader.startProject(id: project.id, port: port)
    }
  }

  func requestStopProject(_ project: SavedProjectStatus) {
    guard savedProjectTask == nil else { return }
    beginSavedProjectAction(project.id) { [loader] in
      try await loader.stopProject(id: project.id)
    }
  }

  func requestRestartProject(_ project: SavedProjectStatus, port: Int) {
    guard savedProjectTask == nil else { return }
    beginSavedProjectAction(project.id) { [loader] in
      try await loader.restartProject(id: project.id, port: port)
    }
  }

  func requestTakeOverProject(_ group: ProjectGroup) {
    guard let project = group.savedProject, savedProjectTask == nil else { return }
    let serviceIDs = group.stopAllTarget?.serviceIDs ?? []
    activeSavedProjectID = project.id
    isManagingSavedProject = true
    projectActionResult = nil
    projectConfigurationError = nil
    savedProjectTask = Task { [weak self, loader] in
      guard let self else { return }
      do {
        for serviceID in serviceIDs {
          let result = try await loader.stopService(id: serviceID)
          if !result.ok { throw SavedProjectActionFailure(message: result.message) }
        }
        let result = try await loader.startProject(id: project.id, port: nil)
        await self.finishSavedProjectAction(result: result)
      } catch {
        await self.finishSavedProjectAction(error: error)
      }
    }
  }

  func clearProjectActionMessage() {
    projectActionResult = nil
    projectConfigurationError = nil
  }

  private func beginSavedProjectAction(
    _ projectId: String,
    action: @escaping @Sendable () async throws -> SavedProjectRunResult
  ) {
    activeSavedProjectID = projectId
    isManagingSavedProject = true
    projectActionResult = nil
    projectConfigurationError = nil
    savedProjectTask = Task { [weak self] in
      guard let self else { return }
      do {
        await self.finishSavedProjectAction(result: try await action())
      } catch {
        await self.finishSavedProjectAction(error: error)
      }
    }
  }

  private func finishSavedProjectAction(result: SavedProjectRunResult) async {
    projectActionResult = result
    await refresh(force: true)
    endSavedProjectAction()
  }

  private func finishSavedProjectAction(error: Error) async {
    projectConfigurationError = localStatusErrorMessage(error.localizedDescription)
    await refresh(force: true)
    endSavedProjectAction()
  }

  private func endSavedProjectAction() {
    isManagingSavedProject = false
    activeSavedProjectID = nil
    savedProjectTask = nil
  }

  private func stopService(_ service: PortdeckService) async {
    stopFailureMessage = nil
    isStopping = true
    defer {
      isStopping = false
      stoppingServiceID = nil
      stoppingProjectID = nil
      stopTask = nil
    }

    do {
      let result = try await loader.stopService(id: service.id)
      if !result.ok {
        stopFailureMessage = result.message
      }
    } catch {
      stopFailureMessage = error.localizedDescription
    }

    await refresh(force: true)
  }

  private func stopAll(_ target: ProjectStopAllTarget) async {
    stopFailureMessage = nil
    isStopping = true
    defer {
      isStopping = false
      stoppingServiceID = nil
      stoppingProjectID = nil
      stopTask = nil
    }

    var failureMessages: [String] = []
    for serviceID in target.serviceIDs where !Task.isCancelled {
      do {
        let result = try await loader.stopService(id: serviceID)
        if !result.ok {
          failureMessages.append(result.message)
        }
      } catch {
        failureMessages.append(error.localizedDescription)
      }
    }

    stopFailureMessage = PortdeckStopBatchSummary(
      projectName: target.projectName,
      totalCount: target.stoppableCount,
      failureMessages: failureMessages
    ).failureMessage

    await refresh(force: true)
  }

  func copyJSON() {
    guard !rawJSON.isEmpty else {
      return
    }

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(rawJSON, forType: .string)
  }
}

private struct SavedProjectActionFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

func localStatusErrorMessage(_ rawMessage: String, limit: Int = 280) -> String {
  var message = rawMessage
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

  let redactions: [(String, String)] = [
    (#"(?i)((?:authorization:\s*(?:bearer|token)|bearer|access[_ -]?token|api[_ -]?key|secret|token)\s*[=:]?\s*)\S+"#, "$1<redacted>"),
    (#"(?i)([?&](?:access_token|api_token|token|api_key|key)=)[^&\s]+"#, "$1<redacted>"),
    (#"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]{10,})?"#, "<redacted>")
  ]
  for (pattern, replacement) in redactions {
    message = message.replacingOccurrences(
      of: pattern,
      with: replacement,
      options: .regularExpression
    )
  }

  guard !message.isEmpty else { return "Local status refresh failed." }
  guard message.count > limit else { return message }
  return String(message.prefix(max(0, limit - 1))) + "…"
}
