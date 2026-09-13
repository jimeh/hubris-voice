import HubrisVoiceCore
import SwiftUI

struct DictationSettingsTab: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var localModels: LocalModelsController

  init(model: AppModel) {
    self.model = model
    localModels = model.localModels
  }

  var body: some View {
    Form {
      Section("Transcription engine") {
        SettingsRow(
          title: "Engine",
          caption: "OpenAI sends audio to the cloud. On-device keeps transcription on this Mac."
        ) {
          Picker("Transcription engine", selection: $localModels.engine) {
            ForEach(TranscriptionEngineSelection.allCases, id: \.self) { engine in
              Text(engine.title).tag(engine)
            }
          }
          .labelsHidden()
          .frame(width: 220)
        }
        if localModels.pendingConfiguration {
          Text("The change will apply after current dictation finishes.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if localModels.engine == .openAI {
        Section("OpenAI") {
          SettingsRow(
            title: "API key",
            caption: "Stored in your login Keychain. Audio is sent directly to OpenAI."
          ) {
            HStack {
              SecureField("API key", text: $model.apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { model.saveAPIKey() }
              Button("Save") { model.saveAPIKey() }
                .buttonStyle(.borderedProminent)
            }
          }
          if let message = model.settingsMessage {
            Text(message)
              .font(.caption)
              .foregroundStyle(model.errorMessage == nil ? .secondary : Color.voiceCoral)
          }
          SettingsRow(
            title: "Languages",
            caption: "Hints for the model. Pick the ones you actually speak."
          ) {
            LanguagePicker(selection: $model.languages)
          }
        }
        Section {
          TextEditor(text: $model.prompt)
            .font(.system(.body, design: .rounded))
            .frame(minHeight: 72)
          HStack {
            Text("Applied live with a short delay. No reconnect needed.")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            configurationBadge
          }
        } header: {
          Text("Transcription context")
        }
      } else {
        Section("On-device model") {
          Picker("Model", selection: $localModels.modelID) {
            Text("Parakeet Unified · English").tag(LocalModelCatalog.primaryID)
            if localModels.modelID != LocalModelCatalog.primaryID {
              Text("Unavailable model").tag(localModels.modelID)
            }
          }
          Text("English transcription with live text. Download and manage its files in Models.")
            .font(.caption).foregroundStyle(.secondary)
          Text(localModels.loadState.title)
          SettingsRow(
            title: "Dictionary correction",
            caption: "Optional. Uses a separate local correction model; review corrections before relying on them."
          ) {
            Toggle("Local dictionary correction", isOn: $localModels.correctionEnabled)
              .labelsHidden()
              .disabled(!localModels.installedIDs.contains(LocalModelCatalog.correctionID))
          }
          if !localModels.installedIDs.contains(LocalModelCatalog.correctionID) {
            Text("Download Dictionary correction in Models to enable it.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section("Insertion") {
        SettingsRow(
          title: "Smart leading space",
          caption: "Adds a space before the text when the caret follows a word."
        ) {
          Toggle("Smart leading space", isOn: $model.smartLeadingSpace).labelsHidden()
        }
        SettingsRow(title: "Trailing space") {
          Toggle("Trailing space", isOn: $model.trailingSpace).labelsHidden()
        }
        SettingsRow(
          title: "Adjust case after commas",
          caption: "Lowercases the first word after a comma. Skips dictionary terms, \"I\", and words with internal capitals."
        ) {
          Toggle("Adjust case after commas", isOn: $model.adjustCaseAfterComma).labelsHidden()
        }
      }
      Section("Audio") {
        SettingsRow(
          title: "Input device",
          caption: "Falls back to the system default when the device is missing."
        ) {
          Picker("Input device", selection: $model.inputDeviceUID) {
            Text("System default").tag(String?.none)
            ForEach(model.inputDevices, id: \.uid) { device in
              Text(device.name).tag(String?.some(device.uid))
            }
          }
          .labelsHidden()
          .frame(width: 220)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear { model.refreshInputDevices() }
  }

  @ViewBuilder
  private var configurationBadge: some View {
    switch model.configurationState {
    case .applied: StatusBadge(text: "Applied", tone: .positive)
    case .pending: StatusBadge(text: "Applying…", tone: .neutral)
    case .failed(let message): StatusBadge(text: message, tone: .attention)
    }
  }
}

private struct LanguagePicker: View {
  @Binding var selection: [String]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(selection, id: \.self) { code in
        Text(name(for: code))
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.signalBlue.opacity(0.14), in: Capsule())
      }
      Menu {
        ForEach(RealtimeSessionConfiguration.supportedLanguages, id: \.code) { language in
          Button {
            toggle(language.code)
          } label: {
            if selection.contains(language.code) {
              Label(language.name, systemImage: "checkmark")
            } else {
              Text(language.name)
            }
          }
        }
      } label: {
        Image(systemName: "plus.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func name(for code: String) -> String {
    RealtimeSessionConfiguration.supportedLanguages.first { $0.code == code }?.name ?? code
  }

  private func toggle(_ code: String) {
    if let index = selection.firstIndex(of: code) {
      guard selection.count > 1 else { return }
      selection.remove(at: index)
    } else {
      selection.append(code)
    }
  }
}
