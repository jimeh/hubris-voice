import AppKit

@MainActor
final class SoundCues {
  func playStart() {
    play(named: "Tink")
  }

  func playStop() {
    play(named: "Pop")
  }

  func playPasted() {
    play(named: "Glass")
  }

  func playRejected() {
    play(named: "Basso")
  }

  private func play(named name: String) {
    NSSound(named: NSSound.Name(name))?.play()
  }
}
