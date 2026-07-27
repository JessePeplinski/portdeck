import Foundation
import PortDeckCore
import Testing
@testable import PortDeckMac

@MainActor
@Test func usesMinuteHostingerPollingAndCancelsWhenOwningTaskEnds() async {
  #expect(HostingerStatusModel.refreshIntervalSeconds == 60)
  let client = FakeHostingerClient(
    responses: Array(repeating: .websites([sampleHostingerWebsite()]), count: 10)
  )
  let model = HostingerStatusModel(client: client, pollInterval: .milliseconds(10))

  let task = Task {
    await model.runAutoRefresh()
  }
  for _ in 0..<100 where await client.callCount < 2 {
    try? await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  await task.value
  let countAfterCancellation = await client.callCount
  try? await Task.sleep(for: .milliseconds(25))

  #expect(countAfterCancellation >= 2)
  #expect(await client.callCount == countAfterCancellation)
}

@MainActor
@Test func preservesLastSuccessfulHostingerSnapshotAcrossFailuresAndReplacesWithEmpty() async {
  let firstDate = Date(timeIntervalSince1970: 1_750_000_000)
  let client = FakeHostingerClient(responses: [
    .websites([sampleHostingerWebsite()]),
    .failure(.transientFailure),
    .failure(.rateLimited),
    .failure(.malformedOutput("Malformed")),
    .websites([])
  ])
  let model = HostingerStatusModel(client: client, now: { firstDate })

  await model.refresh()
  #expect(model.websites.map(\.domain) == ["app.example"])
  #expect(model.lastSuccessfulRefreshAt == firstDate)

  for _ in 0..<3 {
    await model.refresh()
    #expect(model.websites.map(\.domain) == ["app.example"])
    #expect(model.isRetainingSnapshot)
    #expect(model.lastSuccessfulRefreshAt == firstDate)
    #expect(model.errorMessage != nil)
  }

  await model.refresh()
  #expect(model.websites.isEmpty)
  #expect(model.connectionState == .connected)
  #expect(model.errorMessage == nil)
  #expect(!model.isRetainingSnapshot)
}

@MainActor
@Test func reportsFreshHostingerRuntimeAuthenticationRateLimitAndFailureStates() async {
  let cases: [(HostingerCLIError, HostingerConnectionState)] = [
    (.missingCLI, .missingCLI),
    (.unsupportedCLI(currentVersion: "3.6.2"), .unsupportedCLI(currentVersion: "3.6.2")),
    (.authenticationRequired, .authenticationRequired),
    (.rateLimited, .rateLimited(message: HostingerCLIError.rateLimited.localizedDescription)),
    (.commandFailed("Unavailable"), .failed(message: "Unavailable")),
    (.malformedOutput("Malformed"), .failed(message: "Malformed"))
  ]

  for (error, expectedState) in cases {
    let model = HostingerStatusModel(client: FakeHostingerClient(responses: [.failure(error)]))
    await model.refresh()
    #expect(model.connectionState == expectedState)
    #expect(model.websites.isEmpty)
  }
}

@MainActor
@Test func manualHostingerRefreshIsImmediateAndOverlappingRequestsAreIgnored() async {
  let client = FakeHostingerClient(
    responses: [.websites([sampleHostingerWebsite()])],
    delay: .milliseconds(30)
  )
  let model = HostingerStatusModel(client: client)

  async let first: Void = model.refresh()
  try? await Task.sleep(for: .milliseconds(5))
  async let overlapping: Void = model.refresh()
  _ = await (first, overlapping)

  #expect(await client.callCount == 1)
  #expect(model.websites.map(\.domain) == ["app.example"])
}

@MainActor
@Test func filtersHostingerWebsitesWithoutMutatingSnapshot() async {
  let websites = [
    sampleHostingerWebsite(),
    HostingerWebsite(
      domain: "disabled.example",
      isEnabled: false,
      orderID: 22,
      vhostType: "addon"
    )
  ]
  let model = HostingerStatusModel(client: FakeHostingerClient(responses: [.websites(websites)]))
  await model.refresh()

  #expect(model.filteredWebsites(matching: "addon").map(\.domain) == ["disabled.example"])
  #expect(model.websites.count == 2)
}

private actor FakeHostingerClient: HostingerCLIClientProtocol {
  enum Response: Sendable {
    case websites([HostingerWebsite])
    case failure(HostingerCLIError)
  }

  private var responses: [Response]
  private let delay: Duration?
  private(set) var callCount = 0

  init(responses: [Response], delay: Duration? = nil) {
    self.responses = responses
    self.delay = delay
  }

  func fetchWebsites() async throws -> [HostingerWebsite] {
    callCount += 1
    if let delay {
      try await Task.sleep(for: delay)
    }
    guard !responses.isEmpty else {
      return []
    }
    switch responses.removeFirst() {
    case .websites(let websites):
      return websites
    case .failure(let error):
      throw error
    }
  }
}

private func sampleHostingerWebsite() -> HostingerWebsite {
  HostingerWebsite(
    domain: "app.example",
    isEnabled: true,
    orderID: 11,
    parentDomain: "example",
    vhostType: "main"
  )
}
