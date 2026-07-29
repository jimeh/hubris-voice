import Foundation

public enum DictionaryVocabulary {
  public enum ValidationError: Error, Equatable, LocalizedError {
    case invalidCharacters(String)
    case entryTooLong(String)

    public var errorDescription: String? {
      switch self {
      case .invalidCharacters(let entry):
        return "Dictionary entry contains unsupported characters: \(entry)"
      case .entryTooLong(let entry):
        return "Dictionary entry is longer than 80 characters: \(entry)"
      }
    }
  }

  public static func normalize(_ entries: [String]) throws -> [String] {
    var seen: Set<String> = []
    var result: [String] = []

    for rawEntry in entries {
      let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !entry.isEmpty else {
        continue
      }
      guard
        !entry.contains(where: { character in
          character == "<"
            || character == ">"
            || character == "\r"
            || character == "\n"
        })
      else {
        throw ValidationError.invalidCharacters(rawEntry)
      }
      guard entry.count <= 80 else {
        throw ValidationError.entryTooLong(rawEntry)
      }

      let comparisonKey = entry.folding(
        options: [.caseInsensitive, .diacriticInsensitive],
        locale: .current
      )
      guard seen.insert(comparisonKey).inserted else {
        continue
      }
      result.append(entry)
    }

    return result
  }
}
