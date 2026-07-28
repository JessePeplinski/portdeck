import Foundation
import PortDeckCore

@MainActor
final class SupabaseStatusModel: ObservableObject {
  @Published private(set) var connectionState: SupabaseConnectionState = .checking
  @Published private(set) var projects: [SupabaseProject] = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var lastSuccessfulRefreshAt: Date?

  private let client: any SupabaseCLIClientProtocol
  private let now: @Sendable () -> Date

  init(
    client: any SupabaseCLIClientProtocol = SupabaseCLIClient(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.now = now
  }

  var showsHeaderProgress: Bool { isRefreshing }

  func refresh() async {
    await refreshProjects()
  }

  func filteredProjects(matching searchText: String) -> [SupabaseProject] {
    projects.filter { $0.matchesSearch(searchText) }
  }

  private func refreshProjects() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }

    do {
      let projects = try await client.fetchProjects()
      guard !Task.isCancelled else { return }
      self.projects = SupabaseProjectBuilder.sorted(projects)
      connectionState = .connected
      errorMessage = nil
      lastSuccessfulRefreshAt = now()
    } catch {
      guard !Task.isCancelled else { return }
      let message = error.localizedDescription
      errorMessage = message
      switch error {
      case SupabaseCLIError.missingCLI:
        connectionState = .missingCLI
      case SupabaseCLIError.unsupportedCLI(let currentVersion):
        connectionState = .unsupportedCLI(currentVersion: currentVersion)
      case SupabaseCLIError.authenticationRequired:
        connectionState = .authenticationRequired
      case SupabaseCLIError.rateLimited:
        connectionState = .rateLimited(message: message)
      default:
        connectionState = .failed(message: message)
      }
    }
  }
}
