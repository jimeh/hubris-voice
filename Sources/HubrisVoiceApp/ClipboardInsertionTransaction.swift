import AppKit

/// Owns temporary clipboard writes across overlapping insertion requests.
@MainActor
final class ClipboardInsertionTransaction {
  private let pasteboard: NSPasteboard
  private var original: PasteboardSnapshot?
  private var ownedChangeCount: Int?

  init(pasteboard: NSPasteboard) {
    self.pasteboard = pasteboard
  }

  func write(_ text: String) -> Int? {
    if ownedChangeCount != pasteboard.changeCount {
      original = PasteboardSnapshot(pasteboard: pasteboard)
    }
    guard TransientPasteboard.write(text, to: pasteboard) else {
      original?.restore(to: pasteboard)
      original = nil
      ownedChangeCount = nil
      return nil
    }
    ownedChangeCount = pasteboard.changeCount
    return ownedChangeCount
  }

  @discardableResult
  func restore(ifUnchangedSince changeCount: Int) -> Bool {
    guard ownedChangeCount == changeCount else { return false }
    defer {
      original = nil
      ownedChangeCount = nil
    }
    guard pasteboard.changeCount == changeCount, let original else { return false }
    original.restore(to: pasteboard)
    return true
  }
}

private struct PasteboardSnapshot: Sendable {
  private let items: [[String: Data]]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Dictionary(
        uniqueKeysWithValues: item.types.compactMap { type in
          item.data(forType: type).map { (type.rawValue, $0) }
        }
      )
    }
  }

  @MainActor
  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restoredItems: [NSPasteboardItem] = items.map { itemData in
      let item = NSPasteboardItem()
      for (rawType, data) in itemData {
        item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
      }
      return item
    }
    if !restoredItems.isEmpty {
      pasteboard.writeObjects(restoredItems)
    }
  }
}
