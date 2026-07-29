# Hubris Voice

Hubris Voice is a native macOS proof of concept for push-to-talk dictation with
OpenAI's `gpt-live-transcribe` model.

Hold `Control-Shift-Space` to record. A non-activating overlay shows the live
transcript. Release the shortcut to commit the audio; the finalized transcript
is pasted into the text field that was focused when recording began. If focus
changes, the app keeps the transcript in the overlay and offers Copy instead.

## Current scope

- One warm Realtime WebSocket reused across short snippets
- Live transcript preview in a floating overlay
- Custom dictionary terms sent as transcription `keywords`
- Mono 24 kHz PCM16 microphone capture
- API key stored in the macOS login Keychain
- Explicit Microphone and Accessibility permission controls
- Clipboard preservation after synthetic `Command-V`
- Local cancellation of accidental presses shorter than 200 ms

This is a bring-your-own-key developer proof of concept. A distributed product
should issue ephemeral client credentials from a backend instead of shipping or
accepting a long-lived project key in the client.

## Build

Requirements: macOS 15 or newer and Xcode 16 or newer.

```sh
make test
make bundle
```

The bundle is written to:

```text
.build/artifacts/Hubris Voice.app
```

The project has no third-party dependencies. Builds and tests do not connect to
OpenAI.

## First run

Do this when you are available to respond to macOS and firewall prompts:

1. Open `.build/artifacts/Hubris Voice.app`.
2. Open its menu-bar item and choose Settings.
3. Enter an OpenAI API key and choose **Save & reconnect**.
4. Request Microphone and Accessibility access.
5. If macOS also asks for Input Monitoring, allow it.
6. Focus a normal text field, hold `Control-Shift-Space`, speak, and release.

The app does not request system permissions automatically at launch. Permission
prompts happen only when their Request buttons are clicked. It does connect to
OpenAI automatically on later launches when an API key is already stored.

## Development checks

```sh
swift test
swift build
./Scripts/bundle.sh release
plutil -p ".build/artifacts/Hubris Voice.app/Contents/Info.plist"
codesign --verify --deep --strict ".build/artifacts/Hubris Voice.app"
```

See [PLAN.md](PLAN.md) for product decisions, architecture, visual direction,
test strategy, and deferred questions.
