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
    PortdeckHeaderProgressState(isRefreshing: isRefreshing, isStopping: isStopping).showsProgress
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
    if isRefreshing || (!force && isStopping) {
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
