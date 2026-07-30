import AppKit
import PortDeckCore
import SwiftUI
import Testing
@testable import PortDeckMac

@MainActor
@Test func longProjectBranchMovesToASecondHeaderLine() {
  let shortHeader = NSHostingView(rootView: ProjectHeaderLabel(
    projectName: "jessepeplinski.github.io",
    branchMetadata: LocalMetadataItem(text: "main", systemImage: "arrow.triangle.branch"),
    problemLabel: nil
  ).frame(width: 360))
  let longHeader = NSHostingView(rootView: ProjectHeaderLabel(
    projectName: "jessepeplinski.github.io",
    branchMetadata: LocalMetadataItem(
      text: "codex/featured-projects-pep-reviews",
      systemImage: "arrow.triangle.branch"
    ),
    problemLabel: nil
  ).frame(width: 360))

  let shortHeight = shortHeader.fittingSize.height
  let longHeight = longHeader.fittingSize.height

  #expect(longHeight > shortHeight)
}

@MainActor
@Test func sessionDurationFitsBesideShortProjectMetadata() throws {
  let startedAt = try Date("2026-07-30T12:15:00Z", strategy: .iso8601)
  let withoutDuration = NSHostingView(rootView: ProjectHeaderLabel(
    projectName: "PortDeck",
    branchMetadata: LocalMetadataItem(text: "main", systemImage: "arrow.triangle.branch"),
    problemLabel: nil
  ).frame(width: 360))
  let withDuration = NSHostingView(rootView: ProjectHeaderLabel(
    projectName: "PortDeck",
    branchMetadata: LocalMetadataItem(text: "main", systemImage: "arrow.triangle.branch"),
    sessionStartedAt: startedAt,
    problemLabel: nil
  ).frame(width: 360))

  #expect(withDuration.fittingSize.height == withoutDuration.fittingSize.height)
}
