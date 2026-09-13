import Foundation

#if HUBRIS_VOICE_SPARKLE
  import Sparkle

  @MainActor
  final class NativeUpdater {
    let isAvailable = true

    private let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    func checkForUpdates() {
      controller.checkForUpdates(nil)
    }
  }
#else
  @MainActor
  final class NativeUpdater {
    let isAvailable = false

    func checkForUpdates() {}
  }
#endif
