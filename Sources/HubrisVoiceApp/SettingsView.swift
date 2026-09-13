import AppKit
import HubrisVoiceCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
  case general, dictation, dictionary, shortcuts, permissions, history, advanced

  var title: String {
    switch self {
    case .general: "General"
    case .dictation: "Dictation"
    case .dictionary: "Dictionary"
    case .shortcuts: "Shortcuts"
    case .permissions: "Permissions"
    case .history: "History"
    case .advanced: "Advanced"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .dictation: "waveform"
    case .dictionary: "character.book.closed"
    case .shortcuts: "keyboard"
    case .permissions: "checkmark.shield"
    case .history: "clock.arrow.circlepath"
    case .advanced: "slider.horizontal.3"
    }
  }
}

struct SettingsView: View {
  @ObservedObject var model: AppModel
  @State private var selectedTab = SettingsTab.general

  var body: some View {
    TabView(selection: $selectedTab) {
      ForEach(SettingsTab.allCases, id: \.self) { tab in
        tabContent(tab)
          .tabItem { Label(tab.title, systemImage: tab.systemImage) }
          .tag(tab)
      }
    }
    .frame(width: 640, height: 560)
    .onAppear { model.startPermissionPolling() }
    .onDisappear { model.stopPermissionPolling() }
  }

  @ViewBuilder
  private func tabContent(_ tab: SettingsTab) -> some View {
    switch tab {
    case .general: GeneralSettingsTab(model: model)
    case .dictation: DictationSettingsTab(model: model)
    case .dictionary: DictionarySettingsTab(model: model)
    case .shortcuts: ShortcutsSettingsTab(model: model)
    case .permissions: PermissionsSettingsTab(model: model)
    case .history: HistorySettingsTab(model: model)
    case .advanced: AdvancedSettingsTab(model: model)
    }
  }
}

/// A form row with a title, optional caption, and trailing control.
struct SettingsRow<Control: View>: View {
  let title: String
  var caption: String?
  @ViewBuilder let control: () -> Control

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        if let caption {
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 16)
      control()
    }
  }
}

struct StatusBadge: View {
  enum Tone { case positive, attention, neutral }

  let text: String
  let tone: Tone

  var body: some View {
    Label(text, systemImage: symbol)
      .font(.caption)
      .foregroundStyle(color)
  }

  private var symbol: String {
    switch tone {
    case .positive: "checkmark.circle.fill"
    case .attention: "exclamationmark.circle.fill"
    case .neutral: "circle.dashed"
    }
  }

  private var color: Color {
    switch tone {
    case .positive: .completionMint
    case .attention: .voiceCoral
    case .neutral: .secondary
    }
  }
}
