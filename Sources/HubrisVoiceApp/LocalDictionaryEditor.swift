import HubrisVoiceCore
import SwiftUI

struct LocalDictionaryEditor: View {
  @Binding var entries: [LocalVocabularyEntry]
  @State private var canonicalText = ""
  @State private var aliasesText = ""
  @State private var editingIndex: Int?
  @State private var validationMessage: String?

  var body: some View {
    Section {
      Text("These terms and aliases stay on this Mac. They are never added to your OpenAI dictionary.")
        .font(.caption)
        .foregroundStyle(.secondary)
      if entries.isEmpty {
        Text("Add names, technical terms, or identifiers whose spelling matters.")
          .foregroundStyle(.secondary)
      }
      ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 3) {
            Text(entry.canonicalText)
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)
            if !entry.explicitAliases.isEmpty {
              Text(entry.explicitAliases.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          Spacer()
          Button("Edit") { edit(index) }
            .accessibilityLabel("Edit \(entry.canonicalText)")
          Button {
            entries.remove(at: index)
            resetEditor()
          } label: {
            Image(systemName: "trash")
          }
          .accessibilityLabel("Remove \(entry.canonicalText)")
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        TextField("Canonical spelling, for example user_id", text: $canonicalText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Canonical spelling")
          .onSubmit(save)
        TextField("Spoken aliases, separated by commas", text: $aliasesText)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Spoken aliases")
          .onSubmit(save)
        Text(
          "Identifier aliases such as “user underscore ID” are generated automatically. Add other phrases you use to say this term."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if let validationMessage {
          Text(validationMessage).font(.caption).foregroundStyle(Color.voiceCoral)
        }
        HStack {
          Spacer()
          if editingIndex != nil {
            Button("Cancel", action: resetEditor)
          }
          Button(editingIndex == nil ? "Add term" : "Save term", action: save)
            .disabled(canonicalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    } header: {
      Text("Local terms · \(entries.count)")
    }
  }

  private func edit(_ index: Int) {
    editingIndex = index
    canonicalText = entries[index].canonicalText
    aliasesText = entries[index].explicitAliases.joined(separator: ", ")
  }

  private func save() {
    let entry: LocalVocabularyEntry
    do {
      guard let canonical = try DictionaryVocabulary.normalize([canonicalText]).first else { return }
      entry = try LocalVocabularyEntry(
        canonicalText: canonical,
        explicitAliases: DictionaryVocabulary.normalize(aliasesText.components(separatedBy: ","))
      )
    } catch {
      validationMessage = "Use terms and aliases up to 80 characters, without angle brackets or line breaks."
      return
    }
    let canonical = entry.canonicalText
    if let editingIndex, entries.indices.contains(editingIndex) {
      entries[editingIndex] = entry
    } else if let existing = entries.firstIndex(where: {
      $0.canonicalText.caseInsensitiveCompare(canonical) == .orderedSame
    }) {
      entries[existing] = entry
    } else {
      entries.append(entry)
    }
    resetEditor()
  }

  private func resetEditor() {
    editingIndex = nil
    validationMessage = nil
    canonicalText = ""
    aliasesText = ""
  }
}
