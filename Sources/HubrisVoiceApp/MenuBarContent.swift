import AppKit
import HubrisVoiceCore
import SwiftUI

struct MenuBarContent: View {
  @ObservedObject var model: AppModel

  var body: some View {
    Text(model.phaseTitle)
    Text(model.connectionSummary)
    Divider()
    if let latest = model.history.latest {
      Text("Last: \(snippet(latest.text))")
      Button("Copy Last Transcript") { model.copyTranscript(latest) }
    } else {
      Text("No transcripts yet")
    }
    Menu("History") {
      let recent = Array(model.history.entries.prefix(10))
      if recent.isEmpty {
        Text("Empty")
      }
      ForEach(recent) { entry in
        Button(snippet(entry.text)) { model.copyTranscript(entry) }
      }
      Divider()
      Button("Clear History") { model.clearHistory() }
        .disabled(model.history.entries.isEmpty)
    }
    Divider()
    Toggle("Dictation Enabled", isOn: $model.dictationEnabled)
    Button("Reconnect") { model.reconnect() }
    Button("Open Diagnostic Log") { model.openDiagnosticLog() }
    Divider()
    SettingsLink {
      Label("Settings…", systemImage: "gearshape")
    }
    .keyboardShortcut(",")
    Divider()
    Button("Quit Hubris Voice") {
      NSApplication.shared.terminate(nil)
    }
    .keyboardShortcut("q")
  }

  private func snippet(_ text: String) -> String {
    let single = text.replacingOccurrences(of: "\n", with: " ")
    return single.count > 48 ? String(single.prefix(47)) + "…" : single
  }
}
