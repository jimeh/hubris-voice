import AppKit
import SwiftUI

struct SettingsView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        statusHeader
        shortcutSection
        credentialsSection
        dictionarySection
        promptSection
        permissionsSection
      }
      .padding(28)
    }
    .frame(width: 560, height: 650)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      model.refreshPermissions()
    }
  }

  private var statusHeader: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(model.phase.statusColor.opacity(0.14))
          .frame(width: 42, height: 42)
        Image(systemName: model.menuSystemImage)
          .font(.system(size: 19, weight: .semibold))
          .foregroundStyle(model.phase.statusColor)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("Hubris Voice")
          .font(.system(size: 21, weight: .bold, design: .rounded))
        Text(model.phase.title)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Circle()
        .fill(model.phase.statusColor)
        .frame(width: 9, height: 9)
    }
  }

  private var shortcutSection: some View {
    settingSection(title: "Push to talk") {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Global shortcut")
          Text("Hold to record. Release to finalize and paste.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Text("⌃⇧Space")
          .font(.system(.body, design: .monospaced, weight: .semibold))
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(Color.slate.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
      }
    }
  }

  private var credentialsSection: some View {
    settingSection(title: "OpenAI") {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          SecureField("API key", text: $model.apiKeyDraft)
            .textFieldStyle(.roundedBorder)
          Picker("Language", selection: $model.language) {
            Text("English").tag("en")
          }
          .labelsHidden()
          .frame(width: 110)
        }
        HStack {
          Text("Stored in your login Keychain. Audio is sent directly to OpenAI.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Save & reconnect") {
            model.saveSettings()
          }
          .buttonStyle(.borderedProminent)
        }
        if let message = model.settingsMessage {
          Text(message)
            .font(.caption)
            .foregroundStyle(
              model.errorMessage == nil ? .secondary : Color.voiceCoral
            )
        }
      }
    }
  }

  private var dictionarySection: some View {
    settingSection(title: "Custom dictionary") {
      VStack(alignment: .leading, spacing: 12) {
        if model.dictionaryWords.isEmpty {
          Text("Add product names, people, acronyms, or phrases.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
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
              .background(
                Color.signalBlue.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 7)
              )
            }
          }
        }

        HStack {
          TextField(
            "Add a word or phrase",
            text: $model.newDictionaryWord
          )
          .textFieldStyle(.roundedBorder)
          .onSubmit {
            model.addDictionaryWord()
          }
          Button("Add") {
            model.addDictionaryWord()
          }
          .disabled(
            model.newDictionaryWord
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .isEmpty
          )
        }
      }
    }
  }

  private var promptSection: some View {
    settingSection(title: "Transcription context") {
      TextEditor(text: $model.prompt)
        .font(.system(.body, design: .rounded))
        .scrollContentBackground(.hidden)
        .padding(8)
        .frame(minHeight: 76)
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 7)
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
    }
  }

  private var permissionsSection: some View {
    settingSection(title: "Permissions") {
      VStack(spacing: 12) {
        permissionRow(
          title: "Microphone",
          status: model.microphonePermission.label,
          allowed: model.microphonePermission == .authorized,
          buttonTitle: model.microphonePermission == .authorized
            ? nil
            : "Request"
        ) {
          model.requestMicrophonePermission()
        }
        Divider()
        permissionRow(
          title: "Accessibility",
          status: model.accessibilityTrusted ? "Allowed" : "Required",
          allowed: model.accessibilityTrusted,
          buttonTitle: model.accessibilityTrusted ? nil : "Request"
        ) {
          model.requestAccessibilityPermission()
        }
      }
    }
  }

  private func permissionRow(
    title: String,
    status: String,
    allowed: Bool,
    buttonTitle: String?,
    action: @escaping () -> Void
  ) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(
          title == "Microphone"
            ? "Capture speech while the shortcut is held."
            : "Observe the shortcut and paste into the focused app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Label(
        status,
        systemImage: allowed ? "checkmark.circle.fill" : "circle.dashed"
      )
      .font(.caption)
      .foregroundStyle(allowed ? Color.completionMint : .secondary)
      if let buttonTitle {
        Button(buttonTitle, action: action)
      }
    }
  }

  private func settingSection<Content: View>(
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(title.uppercased())
        .font(.system(size: 11, weight: .semibold))
        .tracking(0.8)
        .foregroundStyle(.secondary)
      content()
    }
  }
}

struct MenuBarContent: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Text(model.phase.title)
    Divider()
    SettingsLink {
      Label("Settings…", systemImage: "gearshape")
    }
    Divider()
    Button("Quit Hubris Voice") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }
}
