import Foundation
import HubrisVoiceCore

enum FluidAudioReconfigurationOutcome: Sendable {
  case prepared(FluidAudioCorrectionLease?)
  case failed(FluidAudioCorrectionLease?)
}

struct FluidAudioReconfigurationRequest: Sendable {
  let primaryDirectory: URL
  let existingCorrectionLease: FluidAudioCorrectionLease?
  let needsCorrection: Bool
  let context: LocalInvocationContext
  let correctionPolicy: LocalCorrectionPolicy
}

func prepareFluidAudioReconfiguration(
  request: FluidAudioReconfigurationRequest,
  acquireCorrection: @Sendable () async throws -> FluidAudioCorrectionLease?,
  processor: any FluidAudioProcessing
) async -> FluidAudioReconfigurationOutcome {
  var acquiredCorrectionLease: FluidAudioCorrectionLease?
  do {
    if request.needsCorrection, request.existingCorrectionLease == nil {
      acquiredCorrectionLease = try? await acquireCorrection()
    }
    try Task.checkCancellation()
    let correctionDirectory = request.needsCorrection
      ? (request.existingCorrectionLease ?? acquiredCorrectionLease)?.directory
      : nil
    try await processor.prepare(
      primaryDirectory: request.primaryDirectory,
      correctionDirectory: correctionDirectory,
      context: request.context,
      correctionPolicy: request.correctionPolicy
    )
    try Task.checkCancellation()
    return .prepared(acquiredCorrectionLease)
  } catch {
    return .failed(acquiredCorrectionLease)
  }
}
