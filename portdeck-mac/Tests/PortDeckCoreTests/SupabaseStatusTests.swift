import Foundation
import Testing
@testable import PortDeckCore

@Test func decodesOnlyRenderedSupabaseProjectFieldsAndOptionalTimestamp() throws {
  let envelope = try JSONDecoder().decode(
    SupabaseProjectsEnvelope.self,
    from: Data(#"{"projects":[{"ref":"abcdefghijklmnopqrst","name":"Demo","organization_id":"org-id","organization_slug":"demo-org","region":"us-east-1","status":"ACTIVE_HEALTHY","created_at":"2026-05-27T01:02:03.123Z","database":{"host":"db.example"},"linked":true}]}"#.utf8)
  )
  let project = try #require(envelope.projects.first)

  #expect(project.reference == "abcdefghijklmnopqrst")
  #expect(project.name == "Demo")
  #expect(project.organizationID == "org-id")
  #expect(project.organizationSlug == "demo-org")
  #expect(project.region == "us-east-1")
  #expect(project.platformState == .healthy)
  #expect(project.createdAt != nil)
  #expect(project.dashboardURL?.absoluteString == "https://supabase.com/dashboard/project/abcdefghijklmnopqrst")

  let invalidDate = try JSONDecoder().decode(
    SupabaseProject.self,
    from: Data(#"{"ref":"qrstuvwxyzabcdefghij","name":"No Date","created_at":"not-a-date"}"#.utf8)
  )
  #expect(invalidDate.createdAt == nil)
}

@Test func mapsEveryVerifiedSupabaseStatusAndFutureValuesDefensively() {
  let expected: [SupabasePlatformState: [String]] = [
    .healthy: ["ACTIVE_HEALTHY"],
    .degraded: ["ACTIVE_UNHEALTHY", "INIT_FAILED", "RESTORE_FAILED", "PAUSE_FAILED"],
    .paused: ["INACTIVE"],
    .updating: ["COMING_UP", "GOING_DOWN", "RESTORING", "UPGRADING", "PAUSING", "RESTARTING", "RESIZING"],
    .unknown: ["UNKNOWN", "REMOVED", "FUTURE_STATUS"]
  ]

  for (state, values) in expected {
    for value in values {
      #expect(SupabasePlatformState.map(value) == state)
    }
  }
  #expect(SupabasePlatformState.map(nil) == .unknown)
}

@Test func sortsAndSearchesSupabaseProjectsAcrossProviderMetadata() {
  let projects = [
    supabaseProject("healthy-two", name: "Beta", status: "ACTIVE_HEALTHY"),
    supabaseProject("unknown-one", name: "Delta", status: "FUTURE_STATUS"),
    supabaseProject("paused-one", name: "Charlie", status: "INACTIVE"),
    supabaseProject("updating-one", name: "Bravo", status: "UPGRADING"),
    supabaseProject("degraded-one", name: "Alpha", status: "ACTIVE_UNHEALTHY"),
    supabaseProject("healthy-one", name: "Alpha", status: "ACTIVE_HEALTHY")
  ]

  #expect(SupabaseProjectBuilder.sorted(projects).map(\.platformState) == [
    .degraded, .updating, .paused, .unknown, .healthy, .healthy
  ])
  #expect(SupabaseProjectBuilder.sorted(projects).suffix(2).map(\.name) == ["Alpha", "Beta"])

  let searchable = SupabaseProject(
    reference: "abcdefghijklmnopqrst",
    name: "Launch Loop",
    organizationID: "org-123",
    organizationSlug: "example-org",
    region: "us-east-1",
    rawStatus: "ACTIVE_UNHEALTHY"
  )
  for query in ["launch", "abcdefghijkl", "org-123", "example-org", "us-east", "active_unhealthy", "degraded"] {
    #expect(searchable.matchesSearch(query))
  }
  #expect(!searchable.matchesSearch("missing"))
}

@Test func constructsOnlySafeSupabaseDashboardURLs() {
  #expect(supabaseProject("abcdefghijklmnopqrst", name: "Valid", status: "ACTIVE_HEALTHY").dashboardURL != nil)
  #expect(supabaseProject("too-short", name: "Short", status: "ACTIVE_HEALTHY").dashboardURL == nil)
  #expect(supabaseProject("ABCDEFGHIJKLMNOPQRST", name: "Upper", status: "ACTIVE_HEALTHY").dashboardURL == nil)
  #expect(supabaseProject("abcdefghijklmnopqrs/", name: "Slash", status: "ACTIVE_HEALTHY").dashboardURL == nil)
  #expect(supabaseProject("ébcdefghijklmnopqrst", name: "Unicode", status: "ACTIVE_HEALTHY").dashboardURL == nil)
}

private func supabaseProject(_ reference: String, name: String, status: String) -> SupabaseProject {
  SupabaseProject(reference: reference, name: name, rawStatus: status)
}
