import HubrisVoiceCore
import SwiftUI

struct ModelsSettingsTab: View {
  @ObservedObject var models: LocalModelsController

  var body: some View {
    Form {
      Section("On-device transcription") {
        Text(
          "Parakeet Unified transcribes English on this Mac with live text. "
            + "Downloads require a connection; transcription runs offline."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if !LocalModelsController.hardwareSupported {
          Label("On-device transcription requires Apple Silicon.", systemImage: "exclamationmark.circle")
            .foregroundStyle(Color.voiceCoral)
        }
        SettingsRow(
          title: models.loadState.title,
          caption: "A selected model stays loaded until you unload it or switch engines."
        ) {
          if models.loadState == .loaded || models.loadState == .loading {
            Button("Unload") { models.unload() }
              .disabled(models.isDictating)
          } else {
            Button("Load") { models.load() }
              .disabled(
                !models.installedIDs.contains(LocalModelCatalog.primaryID)
                  || models.loadState == .loading || models.engine != .fluidAudio
                  || !LocalModelsController.hardwareSupported || models.isDictating
              )
          }
        }
        if models.engine != .fluidAudio {
          Text("Select On-device in Dictation to load this model.")
            .font(.caption).foregroundStyle(.secondary)
        }
        if models.pendingConfiguration {
          Text("The engine change will apply after current dictation finishes.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      ForEach(LocalModelCatalog.models) { definition in
        Section(definition.title) {
          modelRow(definition)
          if models.downloadingID == definition.id {
            ProgressView(value: Double(models.progress?.completedBytes ?? 0), total: Double(definition.downloadBytes))
              .accessibilityLabel("Download progress for \(definition.title)")
            HStack {
              Text("\(bytes(models.progress?.completedBytes ?? 0)) of \(bytes(definition.downloadBytes))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
              Spacer()
              Button("Cancel download") { models.cancelDownload() }
            }
          }
          if let licenseURL = definition.licenseURL {
            Link("Model card and license · FluidInference / NVIDIA", destination: licenseURL)
              .font(.caption)
          }
        }
      }
      if let message = models.message {
        Section { Text(message).font(.caption).foregroundStyle(.secondary) }
      }
    }
    .formStyle(.grouped)
    .task { await models.refresh() }
  }

  private func modelRow(_ definition: LocalModelDefinition) -> some View {
    SettingsRow(
      title: models.installedIDs
        .contains(definition.id) ? "Installed · \(bytes(definition.downloadBytes))" : bytes(definition.downloadBytes),
      caption: definition.id == LocalModelCatalog.primaryID
        ? "English · Streaming · 320 ms model window"
        : "Optional download for local dictionary correction."
    ) {
      if models.installedIDs.contains(definition.id) {
        Button("Remove") { models.remove(definition.id) }
          .disabled(models.isDictating || models.downloadingID != nil || models.loadState == .loading)
          .accessibilityLabel("Remove \(definition.title)")
      } else {
        Button("Download") { models.download(definition.id) }
          .disabled(models.downloadingID != nil || models.checking || !LocalModelsController.hardwareSupported)
          .accessibilityLabel("Download \(definition.title)")
      }
    }
  }

  private func bytes(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
  }
}
