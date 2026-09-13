# Hubris Voice

Hubris Voice is a native macOS proof of concept for push-to-talk dictation with
OpenAI's `gpt-live-transcribe` model.

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

This is a bring-your-own-key developer proof of concept. A distributed product
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

The project has no third-party dependencies. Builds and tests do not connect to
OpenAI.

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
are reserved for future notarized distribution builds.

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
OpenAI automatically on later launches when an API key is already stored, and
reconnects on its own after sleep or a network change.

Other settings persist as soon as they change. Prompt, dictionary, and language
edits reach the live session without a reconnect.

## Development checks

```sh
mise tasks
mise run format
mise run check
mise run verify
```

`check` runs formatting checks, SwiftLint, configuration and shell validation,
compilation, and tests. `verify` additionally builds and strictly verifies the
signed release app bundle. Use `mise run doctor` to diagnose local setup and
`mise run logs` to follow the sanitized Realtime diagnostic log.

Lefthook runs fast staged-file formatters and linters before each commit. The
hook is installed by `mise run setup` and can be reinstalled with
`mise run hooks:install`.

The project toolchain is recorded in `mise.toml` and resolved versions and
artifact checksums are committed in `mise.lock`. `mise run tools:update`
updates tools that have cleared the seven-day release cooldown, refreshes the
lockfile, and runs the normal project checks.

See [PLAN.md](PLAN.md) for product decisions, architecture, visual direction,
test strategy, and deferred questions, and
[docs/plans/2026-09-13-daily-driver.md](docs/plans/2026-09-13-daily-driver.md)
for the milestone briefs behind the current feature set.

## Development insertion trace

Quit Hubris Voice, then run `mise run dev:trace` to build and launch a signed
**debug** app with an unsanitized insertion trace.

Each traced process writes a separate `development-<pid>-<uuid>.log` under
`~/Library/Logs/HubrisVoice/`, readable and writable only by your user. These files
contain raw dictated text and focused-field text before and after insertion.
They are for development only; delete them after the investigation. They are not
rotated automatically. Credentials, audio, and previous clipboard contents are
not recorded. The normal `realtime.log` remains sanitized.

The debug-only `--development-trace` launch flag enables tracing. It is ignored
by release builds and never saved in preferences. Quit and relaunch normally to
disable it. Launching an already-running app does not apply new flags.
