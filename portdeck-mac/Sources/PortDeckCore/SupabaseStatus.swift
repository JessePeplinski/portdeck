import Foundation

public enum SupabasePlatformState: String, Equatable, Sendable {
  case degraded
  case updating
  case paused
  case unknown
  case healthy

  public var title: String {
    rawValue.capitalized
  }

  fileprivate var sortRank: Int {
    switch self {
    case .degraded: return 0
    case .updating: return 1
    case .paused: return 2
    case .unknown: return 3
    case .healthy: return 4
    }
  }

  public static func map(_ rawStatus: String?) -> SupabasePlatformState {
    switch rawStatus?.uppercased() {
    case "ACTIVE_HEALTHY":
      return .healthy
    case "ACTIVE_UNHEALTHY", "INIT_FAILED", "RESTORE_FAILED", "PAUSE_FAILED":
      return .degraded
    case "INACTIVE":
      return .paused
    case "COMING_UP", "GOING_DOWN", "RESTORING", "UPGRADING", "PAUSING", "RESTARTING", "RESIZING":
      return .updating
    default:
      return .unknown
    }
  }
}

public struct SupabaseProject: Decodable, Identifiable, Equatable, Sendable {
  public let reference: String
  public let name: String
  public let organizationID: String?
  public let organizationSlug: String?
  public let region: String?
  public let rawStatus: String?
  public let createdAt: Date?

  enum CodingKeys: String, CodingKey {
    case reference = "ref"
    case name
    case organizationID = "organization_id"
    case organizationSlug = "organization_slug"
    case region
    case rawStatus = "status"
    case createdAt = "created_at"
  }

  public init(
    reference: String,
    name: String,
    organizationID: String? = nil,
    organizationSlug: String? = nil,
    region: String? = nil,
    rawStatus: String? = nil,
    createdAt: Date? = nil
  ) {
    self.reference = reference
    self.name = name
    self.organizationID = organizationID
    self.organizationSlug = organizationSlug
    self.region = region
    self.rawStatus = rawStatus
    self.createdAt = createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    reference = try container.decode(String.self, forKey: .reference)
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? reference
    organizationID = try container.decodeIfPresent(String.self, forKey: .organizationID)
    organizationSlug = try container.decodeIfPresent(String.self, forKey: .organizationSlug)
    region = try container.decodeIfPresent(String.self, forKey: .region)
    rawStatus = try container.decodeIfPresent(String.self, forKey: .rawStatus)
    let createdAtString = try container.decodeIfPresent(String.self, forKey: .createdAt)
    createdAt = createdAtString.flatMap(Self.parseTimestamp)
  }

  public var id: String { reference }
  public var platformState: SupabasePlatformState { .map(rawStatus) }

  public var dashboardURL: URL? {
    guard reference.utf8.count == 20,
      reference.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 })
    else {
      return nil
    }
    return URL(string: "https://supabase.com/dashboard/project/\(reference)")
  }

  public func matchesSearch(_ query: String) -> Bool {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return true }
    return [name, reference, organizationID, organizationSlug, region, rawStatus, platformState.title]
      .compactMap { $0?.lowercased() }
      .contains { $0.contains(normalized) }
  }

  private static func parseTimestamp(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
  }
}

public enum SupabaseProjectBuilder {
  public static func sorted(_ projects: [SupabaseProject]) -> [SupabaseProject] {
    projects.sorted { left, right in
      if left.platformState.sortRank != right.platformState.sortRank {
        return left.platformState.sortRank < right.platformState.sortRank
      }
      let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)
      if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
      return left.reference.localizedCaseInsensitiveCompare(right.reference) == .orderedAscending
    }
  }
}

public enum SupabaseConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingRuntime
  case incompatibleRuntime(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}

struct SupabaseProjectsEnvelope: Decodable {
  let projects: [SupabaseProject]
}
