# Milestone 6: history and menu bar

Design brief for milestone 6 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestones 1 to 5. Part A is delegated; part B (menu bar content,
History tab, and icon states) is implemented by the orchestrator.

## Outcome

- Every transcript is retained in memory with its outcome, so a rejected or
  dismissed paste is never lost.
- The menu bar shows connection state and the last transcript, and offers
  copy, history, enable/disable, reconnect, and the log.
- Optional sound cues on start, stop, pasted, and rejected.
- Optional on-disk history, off by default.

## Core

`Sources/HubrisVoiceCore/TranscriptHistory.swift`:

```swift
public struct TranscriptEntry: Equatable, Codable, Identifiable, Sendable {
  public enum Outcome: String, Codable, Sendable { case pasted, attempted, rejected, timedOut, copied, cancelled }
  public let id: UUID
  public let text: String              // unformatted transcript
  public let recordedAt: Date
  public let targetBundleID: String?
  public var outcome: Outcome
}

public struct TranscriptHistory: Equatable, Codable, Sendable {
  public init(limit: Int = 50)
  public var entries: [TranscriptEntry] { get }   // newest first
  public var latest: TranscriptEntry? { get }
  public mutating func record(_ entry: TranscriptEntry)
  public mutating func update(id: UUID, outcome: TranscriptEntry.Outcome)
  public mutating func remove(id: UUID)
  public mutating func clear()
  public func search(_ query: String) -> [TranscriptEntry]   // case and diacritic insensitive substring
}
```

`record` inserts at the front and trims to `limit`. `update` for an
unknown id is a no-op.

`DictationSession` change: `OverlayPresentation` and effects stay as they
are. Add `Effect.recordTranscript(generation: Int, text: String)` emitted
alongside `.insert` when a transcript completes, so the app records the
entry before insertion starts. `Effect.recordOutcome(generation:, outcome:)`
is not needed; the app maps `insertionFinished`, `finalizingTimedOut`, and
`copied` itself.

## App

### History store

- `AppModel.history: TranscriptHistory` published. Map generation to entry
  id while a snippet is live.
- Record on `.recordTranscript`; update outcome on `insertionFinished`
  (`pasted`, `attempted`, `rejected`), `finalizingTimedOut` (`timedOut`,
  with the partial text as a new entry when non-empty), and `copied`.
- `lastTranscript` from milestone 5 becomes `history.latest?.text`.
- Persistence: `history.persist` setting, default false. When on, write
  JSON to `~/Library/Application Support/HubrisVoice/history.json` after
  each change (debounced 1 s) and load at launch. When turned off, delete
  the file. File permissions 0600.
- `targetBundleID` from the captured focus's `NSRunningApplication`.

### Enable and disable

- `settings.dictationEnabled: Bool`, default true, not persisted across
  launches (a disabled state on launch would be confusing). When false,
  presses feed nothing and the menu icon shows the disabled glyph. The
  shortcut monitor keeps running so re-enabling is instant.

### Sound cues

- `SoundCues` service using `NSSound(named:)` system sounds: start "Tink",
  stop "Pop", pasted "Glass", rejected "Basso". Settings:
  `sounds.startStop`, `sounds.pasted`, `sounds.rejected`, all default off.
- Trigger points: `startCapture` effect, `stopCapture` effect, confirmed
  insertion, rejected or attempted insertion.
- Respect the system alert volume; no custom audio files.

### Menu bar model

- `AppModel.connectionSummary: String` for the menu: "Connected · N
  dictionary terms · English", "Reconnecting…", "Add an API key".
- `openDiagnosticLog()` reveals the log file in Finder.
- `reconnect()` feeds `.connectRequested(force: true)`.

## Tests

`TranscriptHistoryTests`: newest first, limit trims oldest, update outcome,
unknown id no-op, remove, clear, search is case and diacritic insensitive,
Codable round-trip.

`DictationSessionTests`: `recordTranscript` is emitted before `insert` on
completion and not for empty transcripts.

Persistence is verified manually.

## Checkpoints

1. Core history and session effect, tests green.
2. App history store, enable/disable, sounds, menu model.
3. Persistence, full validation green.
4. Self-review; report what needs a real macOS run.

## Part B (orchestrator)

Menu bar content per the approved mockup: status line, last transcript with
copy, History submenu with the last ten, Enable/Disable, Reconnect, Open
diagnostic log, Settings, Quit. History tab with search, copy, remove,
clear, and the persistence toggle. Menu icon disabled state and the sounds
section in General.

## Manual verification (user present)

History retains a rejected transcript; copy from the menu; persistence
survives a relaunch when on and the file is deleted when off; sounds play
at each event; disabled state ignores the shortcut.
