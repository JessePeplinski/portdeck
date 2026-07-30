import Foundation
import PortDeckCore

struct ProviderReorderSession {
  let draggedProvider: PortdeckDashboardSource
  let startingOrder: [PortdeckDashboardSource]
  let rowFrames: [PortdeckDashboardSource: CGRect]

  func reorderedProviders(
    from currentOrder: [PortdeckDashboardSource],
    at pointerY: CGFloat
  ) -> [PortdeckDashboardSource] {
    guard
      Set(currentOrder) == Set(startingOrder),
      currentOrder.count == startingOrder.count,
      startingOrder.contains(draggedProvider)
    else {
      return currentOrder
    }

    var reordered = startingOrder.filter { $0 != draggedProvider }
    let requestedIndex = reordered.firstIndex { candidate in
      guard let frame = rowFrames[candidate] else {
        return false
      }
      return pointerY < frame.midY
    } ?? reordered.endIndex
    let firstMovableIndex = reordered.first == .local ? 1 : 0
    reordered.insert(
      draggedProvider,
      at: max(firstMovableIndex, min(requestedIndex, reordered.endIndex))
    )
    return reordered == currentOrder ? currentOrder : reordered
  }
}

struct ProviderReorderPointerSession {
  let originWindowY: CGFloat

  func verticalTranslation(atWindowY currentWindowY: CGFloat) -> CGFloat {
    originWindowY - currentWindowY
  }
}
