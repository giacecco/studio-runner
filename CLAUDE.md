# CLAUDE.md — studio-runner

Native Swift macOS menu bar app for music-production sessions. Two MIDI
push-to-talk buttons learnt at startup:

- **Memo button**: hold + speak → entry appended to
  `.studiorunner.d/raw.md` with a full-screen screenshot and a DAW audio
  clip; DeepSeek consolidates the raw stream into `studiorunner.md`.
- **Ask button**: hold + speak → DeepSeek answers from the current
  state, the reply is appended to `.studiorunner.d/chat.md`, and spoken
  via `AVSpeechSynthesizer`.

## Build & run

```bash
./build.sh                       # release build → .build/StudioRunner.app
open .build/StudioRunner.app     # launch (menu bar icon appears top-right)
log stream --predicate 'process == "StudioRunner"' --style compact
```

The first launch triggers two macOS privacy prompts: **Microphone**
(needed for mic capture) and **Screen Recording** (needed for the
`screencapture -x` call inside each memo). Until both are granted, mic
recording fails and screenshots come out blank.

`build.sh` ad-hoc-codesigns the bundle by default, which is enough for
the entitlements to take effect — but every rebuild changes the
binary's hash, and macOS TCC (Privacy & Security) tracks ad-hoc
identities by hash, so it re-prompts for Microphone / Screen Recording
on each launch. To pin a stable identity across rebuilds, point
`build.sh` at your Developer ID Application certificate:

```bash
STUDIO_SIGN_IDENTITY="Developer ID Application: <Your Name> (TEAMID)" \
  ./build.sh
```

The same flag is what you'd use before distributing the bundle. List
available identities with `security find-identity -v -p codesigning`.

## Architecture

Source layout under `Sources/StudioRunner/`. Single SwiftPM executable
target; the bundle is assembled by hand because SwiftPM doesn't emit
`.app` directly.

| File | Role |
|---|---|
| `AppDelegate.swift` | `@main` entry point; creates the Coordinator + StatusItemController. |
| `Coordinator.swift` | Top-level lifecycle: bootstrap, start/stop session, re-learn buttons, choose project folder, settings window, hot-restart of the DAW recorder when the device changes. Owns every long-lived component below. |
| `StatusItem.swift` | `NSStatusItem` with state-driven SF Symbol icon and dynamic menu. |
| `SettingsWindow.swift` | Modeless `NSWindow` with two controls: DAW input device picker (pre-selects BlackHole 2ch when present) and DeepSeek voice volume slider. Writes through to `Config.setDawDeviceName` / `Config.setTtsVolumePercent` (UserDefaults). |
| `SessionState.swift` | State enum (`idle`, `learningMemo`, `recordingMemo`, `processingMemo`, `recordingAsk`, `askThinking`, `askSpeaking`, `consolidating`, `notReady`, `error`). Drives the icon. |
| `Config.swift` / `EnvFile.swift` | Tunables resolved from UserDefaults (settings window) → process env → `.env` files → defaults. `.env` is loaded from `~/Library/Application Support/StudioRunner/.env`, then the project root, then a sibling of the `.app`. |
| `Layout.swift` | Ensures the project-root directory layout (`studiorunner.md`, `.studiorunner.d/...`). |
| `MIDI.swift` | CoreMIDI client, learn flow (single press + release cycle), push-to-talk gate, JSON persistence of bindings under `.studiorunner.d/midi-bindings.json` (so the next launch goes straight to listening). |
| `CoreAudioDevice.swift` | Finds a CoreAudio input device by display name and enumerates all available inputs for the settings popup. |
| `RollingBuffer.swift` | Fixed-size in-memory PCM ring; extraction derives wall-clock window from how many bytes are in the ring. |
| `MicRecorder.swift` | AVAudioEngine on the default input → convert to 16 kHz mono Int16 → append to ring (with gain). |
| `DAWRecorder.swift` | AVAudioEngine on a specific input device (`AudioUnitSetProperty(CurrentDevice)`) → 44.1 kHz stereo Int16 ring. |
| `WAVWriter.swift` | Minimal RIFF/WAVE header writer for trimmed clips. |
| `Whisper.swift` | `Process` invocation of `whisper-cli` (whisper.cpp). |
| `Screenshot.swift` | `Process` invocation of `screencapture -x`. |
| `DeepSeek.swift` | URLSession POST to DeepSeek's Anthropic-compatible Messages endpoint; assembles the three-layer system prompt. |
| `Speak.swift` | AVSpeechSynthesizer wrapper for the spoken reply. |
| `RawStream.swift` | Append / parse / watermark / prune of `.studiorunner.d/raw.md`. |
| `MemoFlow.swift` | Per-press memo pipeline: extract mic → transcribe → screenshot → DAW clip + transcript → append raw entry → schedule consolidation. |
| `AskFlow.swift` | Per-press ask pipeline: extract mic → transcribe → DeepSeek call with state + raw tail → append chat → speak. |
| `Consolidator.swift` | Serial, debounced actor that rewrites `studiorunner.md` from the post-watermark slice and advances the watermark. |
| `Timestamps.swift` | YYMMDDHHMMSS and YY-MM-DD HH:MM:SS formatters. |

## Dependencies (at runtime)

| Dependency | Why |
|---|---|
| `whisper-cli` (Homebrew `whisper-cpp`) | Local speech-to-text. The bundle inherits the system PATH minus `/opt/homebrew/bin`, so `Config.whisperBinary` probes the usual Homebrew locations directly. |
| `ggml-medium.en.bin` model | Whisper model, ~1.5 GB at `/opt/homebrew/share/whisper-cpp/models/` by default. |
| `screencapture` (macOS built-in) | Full-screen screenshots. |
| BlackHole 2ch (or any virtual loopback) | Optional. If the named CoreAudio input device is missing, DAW capture is skipped and a warning is logged. |
| DeepSeek API key | Consolidation + Q&A. Anthropic-compatible endpoint. Required. |

No Swift packages are pulled in — everything is Apple-provided
(AppKit, AVFoundation, CoreAudio, CoreMIDI, Foundation).

## Environment variables

`Config.swift` reads each variable from process env first, then from
the merged `.env` files. Place a `.env` at one of:

1. `~/Library/Application Support/StudioRunner/.env`
2. The project root selected via the menu
3. A sibling of the `.app` (dev convenience)

| Variable | Default | Purpose |
|---|---|---|
| `STUDIORUNNER_AI_API_KEY` | — | **Required.** DeepSeek key. Until set, the menu shows "Not ready". |
| `STUDIO_DEEPSEEK_MODEL` | `deepseek-chat` | Switch to `deepseek-reasoner` for heavier reasoning. |
| `STUDIO_PROJECT_ROOT` | UserDefaults / Documents | Project folder. Override by env var at first launch, or pick interactively via the menu. |
| `STUDIO_NOTES_FILE` | `studiorunner.md` | Consolidated state filename. |
| `STUDIO_RUNNER_DIR` | `.studiorunner.d` | Hidden directory for raw, chat, audio, screenshots, bindings. |
| `STUDIO_SYSTEM_FILE` | `system.md` | Filename (inside `STUDIO_RUNNER_DIR`) of per-project context prepended to every DeepSeek system prompt. |
| `STUDIO_TTS` | `1` | `0` disables spoken replies. |
| `STUDIO_TTS_VOICE` | unset | AVSpeechSynthesisVoice name match (e.g. `Serena`). |
| `STUDIO_TTS_VOLUME` | unset | 0–100 mapped to `AVSpeechUtterance.volume`. Independent of system volume. |
| `STUDIO_PRUNE_ASSETS` | `0` | `1` deletes audio + screenshot for each entry after it gets consolidated. |
| `WHISPER_MODEL` | `…/ggml-medium.en.bin` | Whisper model path. |
| `WHISPER_LANG` | `en` | Language code. `nl` for Dutch, etc. |
| `STUDIO_MIC_GAIN` | `25` | Mic gain in dB applied in the AVAudioEngine tap. |
| `STUDIO_MIC_PREROLL` | `0.5` | Seconds of mic audio retained before each button-down. |
| `STUDIO_MIC_POSTROLL` | `0.5` | Seconds of mic audio retained after each button-up. |
| `STUDIO_DAW_DEVICE` | `BlackHole 2ch` | CoreAudio input device used for DAW capture. Set to empty to disable. |
| `STUDIO_DAW_PREROLL` | `10` | Seconds of DAW audio retained before each memo utterance. |

## Output structure

Identical to the previous bun script — `.studiorunner.d/` is hidden so
it doesn't crowd the DAW session folder, and `studiorunner.md` is the
only file at the project root.

```
<projectRoot>/
  studiorunner.md              ← consolidated state — read this
  .studiorunner.d/
    system.md                  ← per-project context, prepended to every DeepSeek system prompt
    raw.md                     ← append-only raw stream, with watermark
    chat.md                    ← Q&A transcript
    midi-bindings.json         ← learnt memo + ask buttons (clear via the menu to relearn)
    screenshots/
      YYMMDDHHMMSS.png         ← screenshot per memo utterance
    audio/
      YYMMDDHHMMSS.wav         ← DAW clip per memo utterance (CD quality)
```

## Key design decisions

- **One menu bar app, no daemon, no IPC.** All the long-lived state
  (MIDI, audio rings, DeepSeek client, consolidation worker) lives
  inside the single `Coordinator`. The status item and menu observe a
  shared `SessionStateStore`.
- **CoreMIDI rather than the old @julusian/midi node binding.** The
  client opens every available source and broadcasts events on a
  serial dispatch queue. Subscribers (learn flow, push-to-talk gate)
  attach via `subscribe(_:)` and the gate suppresses simultaneous
  presses via a single `activeBinding` slot.
- **Why MIDI**: CoreMIDI broadcasts to every listener, so we tap
  whatever pedals/pads the user already has within reach without
  stealing input from the DAW, and there's no Accessibility-permission
  dance like a global keyboard hotkey would need.
- **Bindings persist across launches.** Once learnt, the memo + ask
  bindings are saved to `.studiorunner.d/midi-bindings.json`; the next
  session goes straight to listening. "Re-learn buttons…" in the menu
  clears the file and triggers the learn flow again.
- **AVAudioEngine + AVAudioConverter for both inputs.** No `sox`
  subprocesses, no raw temp files on disk. The default input feeds the
  mic ring; an audio unit with `kAudioOutputUnitProperty_CurrentDevice`
  overridden to BlackHole feeds the DAW ring. Both rings live in
  memory at fixed capacity.
- **In-memory ring buffer with wall-clock-aware extraction.** Same
  insight as the bun script: don't trust spawn-time timestamps — derive
  the wall-clock time of the oldest byte from `now − bytesInRing /
  bytesPerSecond`. This self-corrects for tap-thread jitter.
- **Memo flow writes raw.md *first*, then DeepSeek.** A crash or
  network failure during consolidation can never lose a note.
- **Three-layer system prompt** assembled inside `DeepSeek.call(...)`:
  1. `Config.baseRole` — hardcoded persona, always present.
  2. `.studiorunner.d/system.md` — per-project user-edited context.
  3. Call-specific prompt — consolidation format rules, or the ask
     flow's "use the context, say so if it's missing" guidance.
  Joined with `\n\n---\n\n`. `studiorunner.md` is NOT in the system
  prompt — it lives in the user message because it's dynamic state.
- **Speaker label in raw entries.** Each utterance is logged as `The
  Producer: <text>` (and `DAW: <text>` if a DAW transcript exists). The
  label distinguishes mic from DAW transcript when DeepSeek reads the
  raw stream; no actual speaker-identification happens.
- **DeepSeek via the Anthropic-compatible endpoint**
  (`/anthropic/v1/messages`, `x-api-key`, `anthropic-version:
  2023-06-01`). OpenAI-style mode is not used — kept consistent with
  the user's other tooling.
- **TTS via AVSpeechSynthesizer**, not `say` + `afplay`. Volume is set
  directly on `AVSpeechUtterance.volume` (0.0–1.0), bypassing the
  modern macOS voices' silent ignore of inline `[[volm]]` directives.
- **No `Process` spawning except for two specific binaries**:
  `whisper-cli` and `screencapture`. They're independent native tools
  that the bun script also called out to; rewriting whisper.cpp
  bindings in Swift would multiply the build complexity without
  changing the architecture.
- **Graceful DAW degradation.** If `STUDIO_DAW_DEVICE` is missing or
  empty, the DAW recorder is skipped and one warning is logged. The
  mic + assistant continue working without DAW capture. If MIDI has no
  sources, `MIDIClient.openAllSources` throws and the state goes to
  `.error` — push-to-talk is the only input method, so the session
  can't start without it.
- **Privacy prompts**: NSMicrophoneUsageDescription is in `Info.plist`
  so AVAudioEngine.start triggers the macOS prompt on first run.
  `screencapture` needs Screen Recording permission granted manually
  in System Settings the first time. The entitlements file declares
  `audio-input`, `network.client`, and `files.user-selected.read-write`
  to keep the hardened runtime happy after Developer ID signing.

## Manual steps the user handles

- Re-sign with a Developer ID certificate (see `build.sh`'s comments).
- Grant Microphone + Screen Recording permissions on first launch.
- Optionally drag `StudioRunner.app` into `/Applications` and add it to
  Login Items.
- Set the API key in `~/Library/Application Support/StudioRunner/.env`
  for persistent use, or via the shell env when launching during dev.

## Legacy

The original `studio-runner.ts` (Bun CLI) has been removed in this
commit. Git history preserves the reference implementation; the Swift
port mirrors its flow file-for-file.
