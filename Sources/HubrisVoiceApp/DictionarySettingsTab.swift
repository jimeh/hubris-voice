import HubrisVoiceCore
import SwiftUI

struct DictionarySettingsTab: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var localModels: LocalModelsController

  init(model: AppModel) {
    self.model = model
    localModels = model.localModels
  }

  var body: some View {
    Form {
      if localModels.engine == .fluidAudio {
        LocalDictionaryEditor(entries: $localModels.entries)
      } else {
        Section {
          Text("These terms are sent to OpenAI. Select On-device in Dictation to edit your separate local dictionary.")
            .font(.caption).foregroundStyle(.secondary)

          if model.dictionaryWords.isEmpty {
            Text(
              "Add product names, people, acronyms, or phrases. Terms are sent as transcription keywords and applied live."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            LazyVGrid(
              columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
              alignment: .leading,
              spacing: 8
            ) {
              ForEach(model.dictionaryWords, id: \.self) { word in
                HStack(spacing: 6) {
                  Text(word)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                  Spacer(minLength: 2)
                  Button {
                    model.removeDictionaryWord(word)
                  } label: {
                    Image(systemName: "xmark")
                      .font(.system(size: 9, weight: .bold))
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel("Remove \(word)")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.signalBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
              }
            }
          }
          HStack {
            TextField("Add a word or phrase", text: $model.newDictionaryWord)
              .textFieldStyle(.roundedBorder)
              .onSubmit { model.addDictionaryWord() }
            Button("Add") { model.addDictionaryWord() }
              .disabled(model.newDictionaryWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
          if let message = model.settingsMessage, model.errorMessage == nil {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text("OpenAI terms · \(model.dictionaryWords.count)")
        }
      }
    }
    .formStyle(.grouped)
  }
}
