# CLAUDE.md — studio-runner

Voice-driven companion for music production sessions. Two MIDI buttons:
hold the **memo** button to log a note (transcribed via whisper-cpp,
screenshot, DAW audio clip); hold the **ask** button to put a question
to a DeepSeek-backed assistant that's been kept current via a
consolidated track-state markdown.

Single CLI: `bun run studio-runner.ts`. No MCP server, no `listen.ts`.
The `prune` subcommand drops already-consolidated raw entries.

> **Status — untested end-to-end.** The two-button MIDI learn loop,
> memo + ask flows through DeepSeek, and `say` playback have not yet
> been exercised against real hardware and a real
> `STUDIORUNNER_AI_API_KEY`. The missing-key exit-1 path and the
> `prune` subcommand have been smoke-tested. A live session run is
> needed before this is trusted.

## Architecture

- **`studio-runner.ts`** — the whole thing. Module-level state for both
  MIDI bindings, two press queues (memo + ask), three async workers
  (memo, ask, consolidation), DeepSeek client, rolling sox processes for
  mic + DAW. Bootstraps at the bottom under `import.meta.main`.

## Dependencies

| Dependency | Purpose |
|---|---|
| `sox` (Homebrew) | Microphone + DAW capture |
| `whisper-cpp` (Homebrew) | Local speech-to-text via Metal on Apple Silicon |
| `ggml-medium.en.bin` model | ~1.5 GB, at `/opt/homebrew/share/whisper-cpp/models/` |
| `screencapture` (macOS built-in) | Full-screen screenshots |
| `say` (macOS built-in) | TTS playback of the assistant's reply |
| `@julusian/midi` (npm) | CoreMIDI access for the two push-to-talk gates |
| DeepSeek API key | Consolidation + Q&A. Anthropic-compatible endpoint. Required. |
| `bun` | TypeScript runtime |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STUDIORUNNER_AI_API_KEY` | — | **Required.** DeepSeek API key. Script refuses to start without it. |
| `STUDIO_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek model id; `deepseek-reasoner` for slower/heavier reasoning |
| `STUDIO_PROJECT_ROOT` | `cwd` | Project folder where `studiorunner.md` lives |
| `STUDIO_NOTES_FILE` | `studiorunner.md` | Consolidated state filename |
| `STUDIO_RUNNER_DIR` | `.studiorunner.d` | Hidden directory for raw stream, chat log, audio, screenshots |
| `STUDIO_TTS` | `1` | `0` disables `say` playback of assistant replies |
| `STUDIO_TTS_VOICE` | unset | Passed through to `say -v` if set |
| `STUDIO_PRUNE_ASSETS` | `0` | `1` deletes audio + screenshot for each entry as it gets consolidated |
| `WHISPER_MODEL` | `…/ggml-medium.en.bin` | Whisper model path |
| `WHISPER_LANG` | `en` | Language code; set to `nl` for Dutch |
| `STUDIO_MIC_GAIN` | `25` | Microphone gain in dB applied to the rolling mic buffer |
| `STUDIO_MIC_PREROLL` | `0.5` | Seconds of mic audio retained before each button-down |
| `STUDIO_MIC_POSTROLL` | `0.5` | Seconds of mic audio retained after each button-up (catches the tail of the last syllable) |
| `STUDIO_DAW_DEVICE` | `BlackHole 2ch` | CoreAudio input device used for DAW capture. Set to `""` to disable. |
| `STUDIO_DAW_PREROLL` | `10` | Seconds of DAW audio retained before each memo utterance |

## Output structure

```
<STUDIO_PROJECT_ROOT>/
  studiorunner.md              ← consolidated state — read this
  .studiorunner.d/
    raw.md                     ← append-only raw stream, with watermark
    chat.md                    ← Q&A transcript
    screenshots/
      YYMMDDHHMMSS.png         ← screenshot per memo utterance
    audio/
      YYMMDDHHMMSS.wav         ← DAW clip per memo utterance (CD quality)
```

`studiorunner.md` is the only file at the project root; everything else
is hidden under `.studiorunner.d/` so the folder stays clean next to the
DAW's session files.

## Key design decisions

- **Two MIDI bindings learned at startup**: `learnTwoBindings()` opens
  every CoreMIDI input port, then runs `captureBinding` twice — first
  prompting for the memo button, then the ask button. Each press is
  bound to the first Note On (vel > 0) or CC (value ≥ 64) seen; the
  function then waits for the matching "up" before returning, so the
  session doesn't start mid-press. Identity-collision is checked — if
  the same button is offered twice, the second attempt is rejected and
  the user is re-prompted.
- **Why MIDI**: CoreMIDI broadcasts to every listener, so we tap
  whatever pedals/pads the user already has within reach without
  stealing input from the DAW, and there's no Accessibility permission
  dance like a global keyboard hotkey would need.
- **Always-on mic rolling buffer**: A single sox process records the mic
  continuously into `/tmp/studio-runner-mic-rolling.raw` (16 kHz mono
  16-bit). The button events only record timestamps; the worker later
  runs `sox … trim` over `[pressStart − MIC_PREROLL, pressEnd +
  MIC_POSTROLL]` to produce the per-utterance clip. This eliminates the
  200–700 ms sox CoreAudio cold-start gap that would otherwise eat the
  first words, and the post-roll catches the tail of the last syllable
  when the release comes slightly before the user has finished
  speaking. At 32 KB/s mic usage is ~115 MB/hour.
- **Raw PCM rolling files (no WAV header)**: Both rolling buffers are
  written with `-e signed-integer -t raw`. WAV would clip the tail: sox
  doesn't finalise the RIFF size and `data` chunk size until close, so
  a `sox trim` against a still-recording WAV reads only up to whatever
  the stale header advertises and silently drops the rest. Raw has no
  header, so "what's readable" is simply "what's on disk".
- **File-size-derived recording start**: `extract{Mic,Daw}Clip` derives
  the rolling recording's wall-clock start from `statSync(path).size /
  bytesPerSec` at extraction time, not from `Date.now()` at sox spawn.
  This self-corrects for both sox's variable CoreAudio cold-start and
  the OS write-buffer lag, either of which would otherwise slide the
  trim offset off the real start of speech.
- **Flush wait + post-roll**: Before extraction, the worker sleeps
  500 ms so sox can flush its write buffer. Combined with
  `STUDIO_MIC_POSTROLL` (default 0.5 s), the extraction window is
  reliably on disk by the time we run `sox trim`.
- **Memo flow writes raw.md *first*, then DeepSeek**: Each utterance is
  fully captured (transcribe + screenshot + DAW clip + DAW transcribe)
  and appended to `.studiorunner.d/raw.md` before any DeepSeek call.
  This way a crash or network failure during consolidation can never
  lose a note. The raw entry block records `ts:`, `audio:`,
  `screenshot:`, the mic transcript, and the DAW transcript when
  non-empty.
- **Consolidation worker (serial, debounced)**: A single async worker
  drains a `consolidationPending` flag. On each tick it reads
  `studiorunner.md` (current state) + the post-watermark slice of
  `raw.md` (new entries), asks DeepSeek to produce the full updated
  state, atomically rewrites `studiorunner.md`, then advances the
  watermark in `raw.md`. Bursts collapse to at most one extra pass.
- **Watermark in raw.md**: First line is
  `<!-- consolidated_through: <ts | "none"> -->`. The consolidator
  advances it; the `prune` subcommand drops every entry with `ts <=`
  the watermark. The ask flow re-reads the post-watermark slice
  directly, so a freshly-spoken note can be referenced in the next
  question even before consolidation has caught up.
- **Ask flow**: Mirrors the memo flow up to the transcription, then
  hits DeepSeek with the current state + raw tail + the question. The
  answer is logged to stderr, appended to `.studiorunner.d/chat.md`,
  and spoken via `say` (fire-and-forget, so the user can immediately
  hold the memo button again while the answer is being read).
- **DeepSeek client uses the Anthropic-compatible endpoint**
  (`/anthropic/v1/messages`, `x-api-key`, `anthropic-version:
  2023-06-01`, `system` + `messages` + `max_tokens`). The OpenAI-style
  path is *not* used — Anthropic mode is preferred for consistency with
  the rest of the user's tooling.
- **`STUDIORUNNER_AI_API_KEY` is mandatory**: missing it is a hard exit-1 at
  startup before any MIDI prompt or recorder is touched. The `prune`
  subcommand is exempt.
- **Subprocess control via `Bun.spawn`**: Used instead of the `$`
  template tag so the sox process handles are available for `.kill()`
  on release or stop. `say` is launched via `Bun.spawn` too, so the
  arguments don't pass through a shell.
- **Deduplication**: Consecutive identical mic transcriptions on the
  memo queue are suppressed. A genuine duplicate resets the guard so
  the same phrase can reappear after a pause.
- **DAW capture (parallel recorder)**: A second sox process records
  DAW output from a virtual loopback device (`STUDIO_DAW_DEVICE`,
  default `BlackHole 2ch`) into `/tmp/studio-runner-daw-rolling.raw`
  at CD quality (44.1 kHz / 16-bit / stereo). Captured via
  `-t coreaudio "<device>"`. On each memo utterance,
  `extractDawClip` runs `sox … trim` over `[speech_start −
  STUDIO_DAW_PREROLL, speech_end]` and writes the clip to
  `.studiorunner.d/audio/`; then `resetDawRecorder` kills sox, deletes
  the rolling file, and spawns a fresh recorder so disk usage stays
  bounded.
- **Asset paths are project-root-relative**: raw entries store paths
  like `.studiorunner.d/audio/<ts>.wav`. The same string can be used
  verbatim by DeepSeek when constructing Session timeline links in
  `studiorunner.md`, and by `prune` / `STUDIO_PRUNE_ASSETS` when
  resolving files to delete.
- **No-speech suppression**: `--no-speech-thold 0.5` returns empty
  output when whisper's no-speech probability exceeds 0.5;
  `--no-fallback` disables the temperature fallback that was the
  dominant source of pattern hallucinations (e.g. "1 to 5" → "1 2 3 4
  5 6 7 8 9 10") under heavy quantisation.
- **Metal GPU**: whisper-cpp runs on Apple Silicon via `whisper-cli
  -t 6`. First invocation after cold boot compiles the Metal library
  (~10 s); subsequent runs are fast.
- **Graceful DAW degradation**: If `STUDIO_DAW_DEVICE` is missing or
  empty, the DAW recorder either fails fast at spawn (watchdog at 1 s)
  or is skipped entirely. The mic + assistant continue working without
  DAW capture; a single warning is logged. If no MIDI input ports are
  present, `learnTwoBindings()` throws — push-to-talk is the only
  input method, so the session can't start without it.
