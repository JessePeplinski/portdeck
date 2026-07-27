import Foundation

public struct HostingerWebsite: Identifiable, Equatable, Sendable {
  public let domain: String
  public let isEnabled: Bool?
  public let orderID: Int?
  public let parentDomain: String?
  public let vhostType: String?
  public let createdAt: Date?

  public init(
    domain: String,
    isEnabled: Bool?,
    orderID: Int?,
    parentDomain: String? = nil,
    vhostType: String? = nil,
    createdAt: Date? = nil
  ) {
    self.domain = domain
    self.isEnabled = isEnabled
    self.orderID = orderID
    self.parentDomain = parentDomain
    self.vhostType = vhostType
    self.createdAt = createdAt
  }

  public var id: String {
    "\(orderID.map(String.init) ?? "unknown"):\(domain.lowercased())"
  }

  public var state: HostingerWebsiteState {
    switch isEnabled {
    case true: return .enabled
    case false: return .disabled
    case nil: return .unknown
    }
  }

  public var publicURL: URL? {
    HostingerSafeLink.publicWebsiteURL(domain: domain)
  }

  public func matchesSearch(_ searchText: String) -> Bool {
    let normalized = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return true }
    return [
      domain,
      parentDomain,
      vhostType,
      orderID.map(String.init),
      state.title
    ]
    .compactMap { $0 }
    .contains { $0.localizedCaseInsensitiveContains(normalized) }
  }
}

public enum HostingerWebsiteState: Equatable, Sendable {
  case enabled
  case disabled
  case unknown

  public var title: String {
    switch self {
    case .enabled: return "Enabled"
    case .disabled: return "Disabled"
    case .unknown: return "Unknown"
    }
  }

  var sortRank: Int {
    switch self {
    case .disabled: return 0
    case .unknown: return 1
    case .enabled: return 2
    }
  }
}

public enum HostingerStatusBuilder {
  public static func sortedWebsites(_ websites: [HostingerWebsite]) -> [HostingerWebsite] {
    websites.sorted { left, right in
      if left.state.sortRank != right.state.sortRank {
        return left.state.sortRank < right.state.sortRank
      }
      let domainComparison = left.domain.localizedCaseInsensitiveCompare(right.domain)
      if domainComparison != .orderedSame {
        return domainComparison == .orderedAscending
      }
      return (left.orderID ?? .max) < (right.orderID ?? .max)
    }
  }
}

public enum HostingerConnectionState: Equatable, Sendable {
  case checking
  case connected
  case missingCLI
  case unsupportedCLI(currentVersion: String)
  case authenticationRequired
  case rateLimited(message: String)
  case failed(message: String)
}

public enum HostingerSafeLink {
  public static let websitesDashboardURL = URL(string: "https://hpanel.hostinger.com/websites")!

  public static func publicWebsiteURL(domain: String) -> URL? {
    let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty,
      normalized.count <= 253,
      normalized.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      normalized.rangeOfCharacter(from: .controlCharacters) == nil,
      !normalized.contains("@"),
      !normalized.contains("/")
    else {
      return nil
    }

    guard let url = URL(string: "https://\(normalized)"),
      url.scheme == "https",
      url.host != nil,
      url.user == nil,
      url.password == nil
    else {
      return nil
    }
    return url
  }
}
