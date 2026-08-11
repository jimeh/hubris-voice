# Hubris Voice agent guide

Hubris Voice is a native macOS push-to-talk dictation proof of concept built as
a Swift package. Use mise as the only project task runner and tool manager.

## Start here

- Run `mise run setup` after cloning to install pinned tools and Git hooks.
- Run `mise tasks` to discover the task surface.
- Run `mise run check` for normal handoff and `mise run verify` for broad or
  release-facing work.
- Use `mise run format` to write formatting changes. SwiftFormat owns layout;
  SwiftLint owns semantic and style diagnostics.
- Update managed tools with `mise run tools:update`; the seven-day release
  cooldown and `mise.lock` keep routine upgrades reproducible.
- Run focused tests with `mise exec -- swift test --filter <TestName>`.

## Project boundaries

- `HubrisVoiceCore` contains testable policy, protocol, and state decisions. It
  must not depend on AppKit or the application target.
- `HubrisVoiceApp` owns macOS system boundaries: AppKit and SwiftUI UI, audio,
  Accessibility, Keychain, event taps, WebSocket transport, and app lifecycle.
- Preserve guarded paste behavior. A weak Electron target permits only a
  same-process, same-frontmost-app attempt; secure or changed targets reject.
- Do not treat `CGEvent.post` as proof that paste succeeded. Unobservable
  Electron insertion remains an attempted outcome with a Copy escape hatch.

## Native validation

- Permission prompts, global shortcuts, audio input, Keychain access, and paste
  into other applications require manual macOS verification with the user
  present.
- Development bundles require an Apple Development identity. The ignored
  `mise.local.toml` may set `HUBRIS_VOICE_SIGNING_IDENTITY`; never commit it.
- Realtime diagnostics are sanitized before they reach
  `~/Library/Logs/HubrisVoice/realtime.log`; inspect them with `mise run logs`.

Product scope, architecture, and manual test coverage live in [PLAN.md](PLAN.md).
User setup and signing instructions live in [README.md](README.md).
