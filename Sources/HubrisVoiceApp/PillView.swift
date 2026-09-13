import AppKit
import HubrisVoiceCore
import SwiftUI

struct PillView: View {
  @ObservedObject var model: OverlayViewModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HStack(spacing: 6) {
        if model.isLocked {
          Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.fog.opacity(0.7))
            .accessibilityLabel("Recording locked")
        }
        indicator
          .frame(width: 22, height: PillLayout.lineHeight)
        if model.pendingCount > 0 {
          Text("+\(model.pendingCount)")
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.fog.opacity(0.55))
        }
      }
      .frame(height: PillLayout.lineHeight)

      if !model.transcript.isEmpty || !model.message.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          if !model.transcript.isEmpty {
            transcript
          }
          if !model.message.isEmpty {
            Text(model.message)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(Color.fog.opacity(0.55))
              .lineLimit(1)
              .frame(height: PillLayout.messageHeight, alignment: .bottomLeading)
          }
        }
      }
    }
    .padding(.top, 10)
    .padding(.bottom, 10)
    .padding(.leading, 14)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background { background }
    .environment(\.colorScheme, .dark)
  }

  private var caretColor: Color {
    switch model.mode {
    case .listening: .signalBlue
    case .finalizing: Color.fog.opacity(0.32)
    case .attention: .clear
    }
  }

  private var styledTranscript: Text {
    Text(model.transcript)
      + Text(PillLayout.caretSuffix).foregroundColor(caretColor)
  }

  @ViewBuilder
  private var transcript: some View {
    let font = Font.system(size: 15.5, weight: .medium, design: .rounded)
    if model.lineCap <= 1 {
      styledTranscript
        .font(font)
        .foregroundStyle(Color.fog)
        .lineLimit(1)
        .fixedSize()
        .frame(width: model.textWidth, height: PillLayout.lineHeight, alignment: .trailing)
        .clipped()
        .mask {
          if model.overflows {
            LinearGradient(
              stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
              startPoint: .leading,
              endPoint: UnitPoint(x: min(1, 48 / max(model.textWidth, 48)), y: 0.5)
            )
          } else {
            Color.black
          }
        }
    } else {
      let visible = CGFloat(max(1, min(model.lineCap, 6)))
      styledTranscript
        .font(font)
        .foregroundStyle(Color.fog)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: model.textWidth, alignment: .topLeading)
        .frame(
          height: model.overflows ? visible * PillLayout.lineHeight : nil,
          alignment: .bottomLeading
        )
        .clipped()
        .mask {
          if model.overflows {
            LinearGradient(
              stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
              startPoint: UnitPoint(x: 0.5, y: 0),
              endPoint: UnitPoint(x: 0.5, y: 26 / (visible * PillLayout.lineHeight))
            )
          } else {
            Color.black
          }
        }
    }
  }

  @ViewBuilder
  private var indicator: some View {
    switch model.mode {
    case .listening:
      LevelBars(levels: model.levels, reduceMotion: reduceMotion)
    case .finalizing:
      FinalizingDots(reduceMotion: reduceMotion)
    case .attention:
      Circle()
        .fill(Color.voiceCoral)
        .frame(width: 8, height: 8)
        .background {
          Circle()
            .fill(Color.voiceCoral.opacity(0.18))
            .frame(width: 16, height: 16)
        }
    }
  }

  private var background: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    return ZStack {
      if !reduceTransparency {
        shape.fill(.ultraThinMaterial)
      }
      shape.fill(Color.carbon.opacity(reduceTransparency ? 1 : 0.88))
      shape.stroke(
        model.mode == .attention ? Color.voiceCoral.opacity(0.35) : Color.white.opacity(0.09),
        lineWidth: 1
      )
    }
  }
}

private struct LevelBars: View {
  let levels: [Float]
  let reduceMotion: Bool

  @State private var pulse = false

  var body: some View {
    HStack(alignment: .center, spacing: 2.5) {
      ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
        Capsule(style: .continuous)
          .fill(Color.signalBlue)
          .frame(width: 3, height: reduceMotion ? 11 : 3 + CGFloat(level) * 17)
      }
    }
    .opacity(reduceMotion ? (pulse ? 1 : 0.7) : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: levels)
    .onAppear {
      guard reduceMotion else { return }
      withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}

private struct FinalizingDots: View {
  let reduceMotion: Bool

  @State private var pulse = false

  var body: some View {
    HStack(spacing: 2.5) {
      ForEach(0 ..< OverlayViewModel.barCount, id: \.self) { _ in
        Circle()
          .fill(Color.fog)
          .frame(width: 3, height: 3)
      }
    }
    .opacity(reduceMotion ? 0.5 : (pulse ? 0.8 : 0.4))
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }
}

extension Color {
  static let carbon = Color(
    red: 0x12 / 255,
    green: 0x14 / 255,
    blue: 0x17 / 255
  )
  static let slate = Color(
    red: 0x24 / 255,
    green: 0x28 / 255,
    blue: 0x2e / 255
  )
  static let fog = Color(
    red: 0xe8 / 255,
    green: 0xec / 255,
    blue: 0xef / 255
  )
  static let signalBlue = Color(
    red: 0x62 / 255,
    green: 0xa8 / 255,
    blue: 0xff / 255
  )
  static let voiceCoral = Color(
    red: 0xff / 255,
    green: 0x74 / 255,
    blue: 0x66 / 255
  )
  static let completionMint = Color(
    red: 0x6d / 255,
    green: 0xd6 / 255,
    blue: 0xa0 / 255
  )
}
