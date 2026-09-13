# Hubris Voice proof of concept

## Outcome

A native macOS menu-bar app for short-form dictation:

1. Hold `Control-Shift-Space`.
2. Speak while a non-activating overlay previews the live transcript.
3. Release the shortcut.
4. Wait for the final transcript, then paste it into the text field that was
   focused when dictation began.

The app keeps one warm OpenAI Realtime transcription session and commits a new
input-audio buffer for each press. It never inserts partial text into the target
application.

## Scope

- SwiftUI settings and menu-bar UI backed by AppKit where macOS-specific
  behavior is needed.
- `gpt-live-transcribe` over the Realtime WebSocket API.
- Mono 24 kHz PCM16 microphone capture.
- Custom dictionary hints, validated locally and sent as `keywords`.
- A contextual transcription prompt.
- Keychain-backed bring-your-own API key.
- Explicit microphone and Accessibility permission controls.
- Insertion at the caret when the transcript arrives. Only a secure field or
  missing text focus prevents an attempt; recovery is a paste-last shortcut and
  an explicit Copy in the menu bar, never an automatic clipboard write.
- One language for the proof of concept, defaulting to English.

Not in scope: accounts, billing, a backend token broker, automatic text
rewrites, transcript history, live partial insertion into other apps, or App
Store distribution.

## Architecture

```text
Global shortcut ─┐
                 ├─ AppModel ───────────── OverlayController
Microphone ──────┘          │
                            ├─ RealtimeTranscriptionClient
                            │    └─ one warm WebSocket, many commits
                            └─ TextInsertionService
                                 └─ focus guard + clipboard paste

Settings ─ API key/Keychain, dictionary, language, prompt, permissions
```

The testable core owns dictionary validation, shortcut matching, wire-event
encoding/decoding, per-item transcript assembly, and paste-safety decisions.
AppKit, audio, Keychain, event taps, and WebSocket transport stay at system
boundaries.

Electron editors that do not expose a focused Accessibility element use a
strict same-process fallback. Paste outcomes distinguish confirmed insertion,
an unconfirmed attempt, and rejection. Launch Services metadata and an early
runtime process check prevent duplicate app instances.

## Interaction and visual design

Audience: people who dictate many short snippets into writing and developer
tools. The primary job is to make recording state unmistakable without taking
keyboard focus.

Palette:

- Carbon `#121417` — overlay ground
- Slate `#24282E` — raised controls
- Fog `#E8ECEF` — primary text
- Signal blue `#62A8FF` — listening
- Voice coral `#FF7466` — finalizing or attention
- Mint `#6DD6A0` — ready and completed

Type roles:

- SF Pro Rounded: overlay state and live transcript
- SF Pro Text: settings and explanatory copy
- SF Mono: shortcut, connection details, and dictionary tokens

Overlay:

```text
╭─ ● Listening ───────────────── 00:04 ─╮
│ Ship the release after the checks…     │
│ ▁▂▄▇▅▃▂  audio ink                     │
╰─ Hold  ⌃⇧Space  ·  release to paste ──╯
```

Settings:

```text
┌─ Hubris Voice ─────────────────────────┐
│ Ready                                  │
│                                       │
│ Shortcut       ⌃⇧Space                 │
│ Language       English                 │
│ OpenAI API key ••••••••••••  [Save]   │
│                                       │
│ Dictionary                            │
│ [ Hucode × ] [ Treeboot × ] [ add… ]  │
│                                       │
│ Permissions  Microphone  Accessibility│
└───────────────────────────────────────┘
```

Signature element: the waveform is an “audio ink” rail. Its color carries state
from blue while listening to coral while finalizing and mint on completion.
Motion is disabled when Reduce Motion is enabled.

Design self-critique: a dark translucent pill plus waveform can easily become a
generic AI overlay. The revision keeps macOS-native spacing, materials, system
controls, and typography; the color treatment is confined to status and audio
ink. No decorative gradients, chat bubbles, or dashboard cards.

## Implementation sequence

1. Establish the Swift package, bundle metadata, and offline build commands.
2. Write failing tests for validation, protocol events, transcript ordering,
   shortcut matching, and paste safety.
3. Implement the core until those tests pass.
4. Implement audio capture and the warm Realtime WebSocket.
5. Add the global push-to-talk monitor, coordinator, overlay, settings, Keychain,
   and guarded paste.
6. Build the `.app`, run unit tests, inspect bundle metadata, and lint the diff.

## Test strategy

- Unit tests: happy and failure cases for every core decision.
- Protocol fixtures: session configuration, partial/final/error/unknown server
  events, malformed payloads, and out-of-order item completion.
- Automated verification: `mise run check` covers formatting, linting,
  compilation, metadata checks, signing-resolver tests, and Swift tests;
  `mise run verify` adds release bundle assembly and strict code-sign checks.
- Manual verification with the user present: microphone and Accessibility
  permission flows, shortcut hold/release, the live pill at each line cap,
  OpenAI connection, insertion after a focus change, secure-field rejection,
  confirmed paste into native apps, attempted paste into Electron apps, the
  paste-last recovery, and duplicate-launch protection.

## Deferred questions

- Whether the preferred long-term shortcut is a configurable chord or the `Fn`
  key.
- Whether a production version should use ephemeral client secrets from a
  backend instead of a user-supplied API key.
- Whether dictionary entries need phrase weighting or per-application profiles.
