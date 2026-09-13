# OpenAI Realtime transcription reference

What this app relies on from the Realtime API and `gpt-live-transcribe`, with
the source for each claim. Read this before changing anything in
`RealtimeProtocol.swift`, `RealtimeTranscriptionClient.swift`, or the
`DictationSession` transition table. Update it when a live run contradicts it.

Official docs:

- Guide: https://developers.openai.com/api/docs/guides/realtime-transcription
- Client events: https://developers.openai.com/api/docs/api-reference/realtime-client-events
- Server events: https://developers.openai.com/api/docs/api-reference/realtime-server-events
- Transcription WebSocket endpoint example: https://developers.openai.com/cookbook/examples/speech_transcription_methods
- Model overview: https://developers.openai.com/docs/guides/realtime

Legend: [docs] from the pages above, [observed] confirmed in this app against
the live API, [assumed] not yet confirmed either way.

## Connection

- [docs] WebSocket to `wss://api.openai.com/v1/realtime?intent=transcription`
  with `Authorization: Bearer <key>`. The app uses a user-supplied project
  key; a distributed product should use ephemeral client secrets.
- [observed] The first useful server event after `session.update` is
  `session.updated`. The app treats that as "ready". Nothing is sent before
  it.
- [assumed] Realtime sessions have a finite maximum lifetime and drop on
  idle. Treat every socket as one that will close, and reconnect with
  backoff. The OpenAI backend owns that provider-specific policy and replay;
  the generic dictation reducer only observes readiness and transcript events.

## Session configuration

[docs] Configuration is a `session.update` client event with
`session.type = "transcription"`:

```json
{
  "type": "session.update",
  "session": {
    "type": "transcription",
    "audio": {
      "input": {
        "format": { "type": "audio/pcm", "rate": 24000 },
        "transcription": {
          "model": "gpt-live-transcribe",
          "prompt": "…",
          "keywords": ["…"],
          "languages": ["en"],
          "delay": "low"
        },
        "turn_detection": null
      }
    }
  }
}
```

- [docs] `keywords` and `languages` are supported by `gpt-live-transcribe`.
  `languages` is an array of ISO-639-1 codes listing possible input
  languages. This model uses `languages`, not the singular `language` field
  used by other transcription models.
- [docs] `delay` is one of `minimal`, `low`, `medium`, `high`, `xhigh`.
  Lower values emit partial text sooner; higher values improve quality.
- [docs] `turn_detection: null` disables server voice activity detection so
  the client decides when a turn ends by committing the buffer. The app
  relies on this for push-to-talk.
- [docs] `session.update` can be sent again on the live socket to change
  prompt, keywords, languages, or delay. The server answers with
  `session.updated`. Omitting a field preserves its current value. The app
  reconnects when clearing all language hints, after active snippets finish,
  because omission on a live session would retain the previous hints.
- [observed] Sending `session.update` immediately after the socket opens,
  before any `session.created` handling, works.

## Audio input

- [docs] `input_audio_buffer.append` carries base64 PCM16 mono at the
  configured rate. The app sends 24 kHz.
- [docs] `input_audio_buffer.commit` ends the current turn. The server
  answers `input_audio_buffer.committed` with the `item_id` of the
  conversation item created from the buffer.
- [docs] An empty commit produces an error. `error.event_id`, when present,
  identifies the client event that failed. The app maps commit event IDs back
  to their generation and removes rejected commits from its acknowledgement
  queue, including after local cancellation or timeout.
- [docs] `input_audio_buffer.clear` discards the uncommitted buffer.
- [observed] Audio appended before `session.updated` is dropped by the
  client. After a reconnect the server has no memory of earlier audio, so
  the app keeps every chunk of a live snippet locally and replays it.

## Transcript events

- [docs] `conversation.item.input_audio_transcription.delta` carries
  `item_id` and `delta`. Deltas are incremental text for the item being
  transcribed.
- [observed] With `turn_detection: null`, deltas stream while audio is still
  being appended, before any commit. The `item_id` on those live deltas is
  the same id later reported by `input_audio_buffer.committed` for that
  turn. The live preview depends on this: the OpenAI adapter associates the
  first delta's `item_id` with its active invocation. Do not assume deltas start at commit.
- [docs] `conversation.item.input_audio_transcription.completed` carries the
  final `transcript` for an `item_id`. The app inserts only this text, never
  partials.
- [observed] After a reconnect and replay, the new socket transcribes the
  replayed audio from scratch under a new `item_id`. Partial text from the
  old socket must be discarded, not appended to.
- [observed] `error` server events can arrive without the socket closing.
  The client keeps the connection; the session presents the message.

## Things not yet verified

- Whether a `session.update` during an active turn applies to that turn or
  the next one. Milestone 4 applies edits after the current snippet.
- Exact session lifetime and idle limits for transcription intent.
- Whether `keywords` has a documented maximum count or length beyond the
  app's own 80-character entry cap.

## Application boundary

`OpenAITranscriptionBackend` owns transport attempts, item IDs, pre-commit
previews, commit rejection correlation, cancelled ACK tombstones, and replay.
It emits full preview replacements and final results addressed by backend epoch
and invocation generation. `DictationSession` handles those common events and
owns gestures, timeouts, pending work, and insertion decisions for both engines.
Cloud configuration accepts only `RealtimeSessionConfiguration`; local
vocabulary and ephemeral context are separate types and persistence keys.
