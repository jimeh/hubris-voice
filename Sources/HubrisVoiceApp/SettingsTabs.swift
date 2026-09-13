import AppKit
import HubrisVoiceCore
import SwiftUI

struct GeneralSettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section("Status") {
        SettingsRow(title: model.phaseTitle, caption: connectionCaption) {
          HStack(spacing: 10) {
            Circle()
              .fill(model.statusColor)
              .frame(width: 9, height: 9)
            Button("Reconnect") { model.reconnect() }
          }
        }
      }
      Section("Behavior") {
        SettingsRow(
          title: "Launch at login",
          caption: model.requiresApproval
            ? "Waiting for approval in System Settings › General › Login Items."
            : "Registered with macOS as a login item."
        ) {
          Toggle("Launch at login", isOn: $model.launchAtLogin)
            .labelsHidden()
        }
        SettingsRow(
          title: "Overlay placement",
          caption: "Automatic places the overlay above the focused field and falls back to the window, then the screen."
        ) {
          Picker("Overlay placement", selection: $model.overlayPlacement) {
            Text("Automatic").tag(OverlayPlacementPreference.automatic)
            Text("Bottom of screen").tag(OverlayPlacementPreference.bottomOfScreen)
            Text("Top of screen").tag(OverlayPlacementPreference.topOfScreen)
          }
          .labelsHidden()
          .frame(width: 170)
        }
        SettingsRow(title: "Dictation enabled", caption: "Also available from the menu bar.") {
          Toggle("Dictation enabled", isOn: $model.dictationEnabled).labelsHidden()
        }
      }
      Section("Sounds") {
        SettingsRow(title: "Start and stop") {
          Toggle("Start and stop", isOn: $model.startStopSoundsEnabled).labelsHidden()
        }
        SettingsRow(title: "Pasted") {
          Toggle("Pasted", isOn: $model.pastedSoundEnabled).labelsHidden()
        }
        SettingsRow(title: "Rejected or failed") {
          Toggle("Rejected or failed", isOn: $model.rejectedSoundEnabled).labelsHidden()
        }
      }
    }
    .formStyle(.grouped)
  }

  private var connectionCaption: String {
    let terms = model.dictionaryWords.count
    let termLabel = "\(terms) dictionary term\(terms == 1 ? "" : "s")"
    let languages = model.languages
      .compactMap { code in
        RealtimeSessionConfiguration.supportedLanguages.first { $0.code == code }?.name
      }
      .joined(separator: ", ")
    return "\(RealtimeAPI.transcriptionModel) · \(termLabel) · \(languages.isEmpty ? "Auto language" : languages)"
  }
}

struct DictationSettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
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

struct DictionarySettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section {
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
        Text("Terms · \(model.dictionaryWords.count)")
      }
    }
    .formStyle(.grouped)
  }
}

struct ShortcutsSettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section("Push to talk") {
        SettingsRow(title: "Shortcut", caption: "Hold to record. Release to finish and insert.") {
          ShortcutRecorder(
            model: model,
            binding: model.shortcuts.pushToTalk,
            role: .pushToTalk,
            allowsClear: false
          )
        }
        SettingsRow(
          title: "Tap to lock",
          caption: "A quick tap starts a locked recording. Tap again to finish."
        ) {
          Toggle("Tap to lock", isOn: $model.tapToLock).labelsHidden()
        }
        SettingsRow(title: "Cancel", caption: "Discards the current dictation.") {
          KeyCap(text: "Esc")
        }
      }
      Section("Recovery") {
        SettingsRow(
          title: "Paste last transcript",
          caption: "Inserts the most recent transcript into the focused field. "
            + "Copies to the clipboard if insertion fails."
        ) {
          ShortcutRecorder(
            model: model,
            binding: model.shortcuts.pasteLastTranscript,
            role: .pasteLastTranscript,
            allowsClear: true
          )
        }
      }
      if let conflict = model.shortcutConflict {
        Section {
          StatusBadge(text: conflict, tone: .attention)
        }
      }
      if model.shortcuts.pushToTalk == .modifier(.fn)
        || model.shortcuts.pasteLastTranscript == .modifier(.fn)
      {
        Section {
          Text(fnWarning)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private let fnWarning =
    "Fn is bound. On some keyboards macOS handles Fn before the shortcut can see it. "
      + "If holding Fn does nothing, choose a different key."
}

private struct PermissionItem {
  let title: String
  let caption: String
  let granted: Bool
  let status: String
  let canRequest: Bool
  let request: () -> Void
  let open: () -> Void
}

struct PermissionsSettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section {
        ForEach(items, id: \.title) { item in
          SettingsRow(title: item.title, caption: item.caption) {
            HStack(spacing: 10) {
              StatusBadge(text: item.status, tone: item.granted ? .positive : .neutral)
              if !item.granted {
                if item.canRequest {
                  Button("Request", action: item.request)
                }
                Button("Open System Settings", action: item.open)
              }
            }
          }
        }
      } footer: {
        Text("Status refreshes every two seconds while this window is open.")
      }
    }
    .formStyle(.grouped)
  }

  private var items: [PermissionItem] {
    [
      PermissionItem(
        title: "Microphone",
        caption: "Capture speech while the shortcut is held.",
        granted: model.microphonePermission == .authorized,
        status: model.microphonePermission.label,
        canRequest: model.microphonePermission == .notDetermined,
        request: model.requestMicrophonePermission,
        open: { model.openSystemSettings(for: .microphone) }
      ),
      PermissionItem(
        title: "Accessibility",
        caption: "Read the focused field and insert text.",
        granted: model.accessibilityTrusted,
        status: model.accessibilityTrusted ? "Allowed" : "Required",
        canRequest: !model.accessibilityTrusted,
        request: model.requestAccessibilityPermission,
        open: { model.openSystemSettings(for: .accessibility) }
      ),
      PermissionItem(
        title: "Input Monitoring",
        caption: "Observe the global shortcut in every app.",
        granted: model.inputMonitoring,
        status: model.inputMonitoring ? "Allowed" : "Not granted",
        canRequest: !model.inputMonitoring,
        request: model.requestInputMonitoringPermission,
        open: { model.openSystemSettings(for: .inputMonitoring) }
      ),
    ]
  }
}

struct HistorySettingsTab: View {
  @ObservedObject var model: AppModel
  @State private var query = ""

  var body: some View {
    Form {
      Section {
        HStack {
          TextField("Search history", text: $query)
            .textFieldStyle(.roundedBorder)
          Button("Clear") { model.clearHistory() }
            .disabled(model.history.entries.isEmpty)
        }
      }
      Section {
        if entries.isEmpty {
          Text(model.history.entries.isEmpty ? "No transcripts yet." : "No matches.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(entries) { entry in
          HistoryRow(entry: entry, model: model)
        }
      }
      Section {
        SettingsRow(
          title: "Keep history across launches",
          caption: "Off by default. Transcripts can contain sensitive text. "
            + "Stored at \(TranscriptHistoryStore.displayPath)."
        ) {
          Toggle("Keep history across launches", isOn: $model.historyPersistenceEnabled).labelsHidden()
        }
      }
    }
    .formStyle(.grouped)
  }

  private var entries: [TranscriptEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? model.history.entries : model.history.search(trimmed)
  }
}

private struct HistoryRow: View {
  let entry: TranscriptEntry
  @ObservedObject var model: AppModel

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(entry.text)
          .font(.system(.body, design: .rounded))
          .lineLimit(3)
        Text(meta)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Button("Copy") { model.copyTranscript(entry) }
      Button {
        model.removeHistoryEntry(id: entry.id)
      } label: {
        Image(systemName: "trash")
      }
      .accessibilityLabel("Remove transcript")
    }
    .padding(.vertical, 2)
  }

  private var meta: String {
    [appName, entry.outcome.label, entry.recordedAt.formatted(date: .omitted, time: .shortened)]
      .compactMap(\.self)
      .joined(separator: " · ")
  }

  private var appName: String? {
    guard let bundleID = entry.targetBundleID else { return nil }
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    return url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
  }
}

extension TranscriptEntry.Outcome {
  var label: String {
    switch self {
    case .pasted: "Pasted"
    case .attempted: "Attempted"
    case .rejected: "Rejected"
    case .timedOut: "Timed out"
    case .copied: "Copied"
    case .cancelled: "Cancelled"
    }
  }
}

struct AdvancedSettingsTab: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Form {
      Section("Diagnostics") {
        SettingsRow(title: "Diagnostic log", caption: "\(DiagnosticLog.displayPath) · sanitized") {
          Button("Show in Finder") { model.openDiagnosticLog() }
        }
      }
    }
    .formStyle(.grouped)
  }
}
