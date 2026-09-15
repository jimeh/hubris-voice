# Hubris Voice

Hubris Voice is a native macOS proof of concept for push-to-talk dictation with
OpenAI's `gpt-live-transcribe` model or on-device Parakeet Unified transcription.

Hold `Control-Shift-Space` to record. A small non-activating pill next to the
field you are dictating into shows the live transcript and a mic-level
indicator; it wraps to a configurable number of lines, three by default, and a
cap of one scrolls sideways instead. Release the shortcut to commit the audio;
the finalized transcript is inserted wherever the caret is at that moment,
using clipboard paste. The pill hides after the insertion attempt. If the app
detects a secure field or no foreground app,
recorded text remains available for recovery. The optional paste-last-transcript
shortcut retries insertion; the menu bar's Copy puts the text on the clipboard
for manual paste. The previous clipboard is restored unless another copy has replaced it.

## Current scope

- One warm Realtime WebSocket with automatic reconnect and backoff; audio
  recorded while disconnected is replayed once the session is ready
- Optional English-only on-device streaming on Apple Silicon, with verified model
  downloads, explicit load/unload controls, a separate local dictionary, and
  opt-in active-window term hints
- Live transcript preview in a pill placed at the caret, with a 1 to 6 line cap
- Clipboard insertion with best-effort content confirmation and temporary markers
  that keep automatic transcripts out of compatible clipboard histories
- Smart leading and trailing spaces at the caret
- Configurable push-to-talk shortcut, including Fn and right-side modifiers,
  tap to lock, Escape to cancel, and an optional paste-last-transcript key
- Custom dictionary terms and multiple languages sent as transcription hints,
  applied live without reconnecting
- Transcript history with outcomes, in memory by default
- Input device selection with recovery from device changes
- API key stored in the macOS login Keychain
- Microphone, Accessibility, and Input Monitoring permission controls
- Launch at login, optional sound cues, and a menu bar with the last
  transcript and history
- Launch Services and runtime protection against duplicate app instances

The OpenAI engine is a bring-your-own-key developer proof of concept. A distributed product
should issue ephemeral client credentials from a backend instead of shipping or
accepting a long-lived project key in the client.

## Build

Requirements: macOS 15 or newer, Xcode 16 or newer, and
[mise](https://mise.jdx.dev/).

```sh
mise run setup
mise run test
mise run bundle
```

The bundle is written to:

```text
.build/artifacts/Hubris Voice.app
```

FluidAudio 0.15.7 is vendored with patches for compiler compatibility and to
disable SDK logging, which otherwise includes vocabulary and transcript text.
Its source and licenses live in [Vendor/FluidAudio](Vendor/FluidAudio), while
the checksum-pinned archive provenance, ordered patches, and maintenance
workflow live in
[third-party/vendor](third-party/vendor/README.md).
Builds can fetch its checksum-pinned native binary dependency. Ordinary tests do
not download speech models or connect to OpenAI.
Signed distribution builds also embed the pinned Sparkle framework for self-updates.

### Development signing

`mise run bundle` signs the app with an Apple Development identity so macOS can
recognize rebuilt versions as the same app and preserve privacy and Keychain
approvals.

If exactly one Apple Development identity is installed, the build selects it
automatically. If none or more than one are available, set
`HUBRIS_VOICE_SIGNING_IDENTITY` to the SHA-1 fingerprint to use:

```sh
security find-identity -v -p codesigning
```

For a local mise override, create the ignored `mise.local.toml`:

```toml
[env]
HUBRIS_VOICE_SIGNING_IDENTITY = "APPLE_DEVELOPMENT_SHA1"
```

Developer ID identities are intentionally ignored by development builds. They
are used only by the notarized distribution workflow.

### Releases

Release Please maintains the changelog and release version. A release packages
a universal Developer ID signed and notarized application as both ZIP and DMG,
publishes a signed Sparkle appcast and SPDX SBOM, and attaches GitHub provenance
and SBOM attestations before making the immutable GitHub Release public.

See [the release runbook](docs/agents/releases.md) for credential setup, manual
verification, publication, and recovery procedures.

## First run

Do this when you are available to respond to macOS and firewall prompts:

1. Open `.build/artifacts/Hubris Voice.app`.
2. Open its menu-bar item and choose Settings.
3. In the Dictation tab, enter an OpenAI API key and choose **Save**.
4. In the Permissions tab, request Microphone and Accessibility access. Allow
   Input Monitoring if macOS asks for it.
5. Focus a normal text field, hold `Control-Shift-Space`, speak, and release.

The app does not request system permissions automatically at launch. Permission
prompts happen only when their Request buttons are clicked. It connects to
OpenAI automatically on later launches when OpenAI is selected and an API key
is already stored, and reconnects after sleep or a network change.

Other settings persist as soon as they change. Prompt, dictionary, and non-empty
language edits reach the live session without a reconnect. Clearing all language
hints reconnects after active snippets finish.

## On-device transcription

OpenAI remains the default. On Apple Silicon, select **On-device · FluidAudio**
in Dictation, then download **Parakeet Unified** in Models. The first model is
English-only and provides live raw previews with finalized text at release.
No API key is needed. Selecting local mode never falls back to cloud transcription.

The primary download is about 608 MB. Dictionary correction adds about
103 MB. Download its files in Models. **Local dictionary correction** in Dictation
defaults to on; a saved off preference is preserved. Local terms have canonical
spellings and optional spoken aliases. Identifier aliases such as `user underscore ID` for
`user_id` are generated automatically. Correction only accepts constrained term
substitutions; it can still make mistakes. If correction fails, usable raw text
is retained and the Models tab reports degraded correction.

The Dictionary tab edits the selected engine's vocabulary. The local dictionary
is initially copied from existing OpenAI terms, then stored separately. Local
entries and aliases never flow back into OpenAI settings. **Use active-window
terms** is off by default. When enabled, it uses macOS Accessibility to read a
bounded set of visible text from the current window after recording starts. It
selects likely identifiers and unusual names for that local invocation only.
Captured text and automatic terms are not persisted, logged, placed in history,
or sent to OpenAI. The feature falls back to the permanent local dictionary when
Accessibility permission, useful visible text, or timely revalidation is absent.
It does not change another application's accessibility or screen-reader settings.

Downloaded models live under `~/Library/Application Support/Hubris Voice/Models`.
Downloads stream into owned staging files and must pass pinned size and SHA-256
checks before installation. FluidAudio receives explicit paths and does not
download models during transcription. macOS manages its own CoreML/driver caches.
Model cards and attribution links are available alongside each download.

A selected local model stays loaded while the app runs. **Unload** releases its
memory and keeps its files and selection. **Load** or the next dictation loads
it again. **Remove** unloads and deletes the selected assets; it is unavailable
during active dictation. Engine and dictionary changes wait for listening,
finalization, and insertion to finish. New recordings cannot indefinitely defer
an engine change.

See [the local transcription reference](docs/reference/local-transcription.md)
for implementation boundaries, offline smokes, and remaining manual checks.

## Development checks

```sh
mise tasks
mise run format
mise run check
mise run verify
```

`check` runs Swift, zsh, and TOML formatting checks, SwiftLint, configuration
and shell validation, compilation, and tests. `verify` additionally builds and
strictly verifies the signed release app bundle. Use `mise run doctor` to
diagnose local setup and
`mise run logs` to follow the sanitized Realtime diagnostic log.

Lefthook runs fast staged-file formatters and linters before each commit. The
hook is installed by `mise run setup` and can be reinstalled with
`mise run hooks:install`.

Linked worktrees can run `mise run treeboot` to copy the main checkout's ignored
`mise.local.toml` once and then run `mise run setup`. Existing worktree-local
copies are preserved.

The project toolchain is recorded in `mise.toml` and resolved versions and
artifact checksums are committed in `mise.lock`. `mise run tools:update`
updates tools that have cleared the seven-day release cooldown, refreshes the
lockfile, and runs the normal project checks.

See
[docs/plans/2026-09-13-daily-driver.md](docs/plans/2026-09-13-daily-driver.md)
for architecture boundaries, remaining manual test coverage, and the milestone
briefs behind the current feature set.

## Development insertion trace

Quit Hubris Voice, then run `mise run dev:trace` to build and launch a signed
**debug** app with an unsanitized development trace.

Each traced process writes a separate `development-<pid>-<uuid>.log` under
`~/Library/Logs/HubrisVoice/`, readable and writable only by your user. These files
contain raw dictated text, focused-field text before and after insertion, and
on-device active-window context including captured fragments, candidates,
classifications, selected terms, generated aliases, and context lifecycle
decisions. Local runs also include raw and candidate correction text plus guard
decisions. They are for development only; delete them after the investigation.
They are not rotated automatically. Credentials, audio, and previous clipboard
contents are not recorded. The normal `realtime.log` remains sanitized.

The debug-only `--development-trace` launch flag enables tracing for both OpenAI
and on-device transcription. It is ignored by release builds and never saved in
preferences. Quit and relaunch normally to disable it. Launching an
already-running app does not apply new flags.
