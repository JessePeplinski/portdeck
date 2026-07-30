import Testing
@testable import PortDeckMac

@Test func keyboardNavigationStartsAtTheEdgeMatchingTheMoveDirection() {
  let ids = ["project", "service-a", "service-b"]

  #expect(LocalKeyboardNavigation.movedSelection(from: nil, by: 1, in: ids) == "project")
  #expect(LocalKeyboardNavigation.movedSelection(from: nil, by: -1, in: ids) == "service-b")
}

@Test func keyboardNavigationMovesAndStopsAtListEdges() {
  let ids = ["project", "service-a", "service-b"]

  #expect(LocalKeyboardNavigation.movedSelection(from: "project", by: 1, in: ids) == "service-a")
  #expect(LocalKeyboardNavigation.movedSelection(from: "service-a", by: -1, in: ids) == "project")
  #expect(LocalKeyboardNavigation.movedSelection(from: "project", by: -1, in: ids) == "project")
  #expect(LocalKeyboardNavigation.movedSelection(from: "service-b", by: 1, in: ids) == "service-b")
}

@Test func keyboardNavigationHandlesMissingAndEmptySelections() {
  let ids = ["project", "service-a"]

  #expect(LocalKeyboardNavigation.movedSelection(from: "stale", by: 1, in: ids) == "project")
  #expect(LocalKeyboardNavigation.movedSelection(from: "project", by: 1, in: []) == nil)
}

@Test func shortcutReferenceCoversEveryImplementedKeyboardPath() {
  let keys = PortDeckKeyboardShortcuts.sections.flatMap(\.shortcuts).map(\.keys)

  #expect(keys.contains("/ or ⌘ F"))
  #expect(keys.contains("↑  ↓"))
  #expect(keys.contains("←  →"))
  #expect(keys.contains("Return"))
  #expect(keys.contains("Escape"))
  #expect(keys.contains("⌘ K"))
  #expect(keys.contains("⌘ R"))
  #expect(keys.contains("⌘ 1–9"))
  #expect(keys.contains("⌃ Tab"))
  #expect(keys.contains("?"))
}
