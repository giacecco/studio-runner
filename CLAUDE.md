# CLAUDE.md — studio-runner

Native Swift macOS menu bar app for music-production sessions. Three MIDI
buttons learnt at startup: a **session button** (hold to arm) and two
push-to-talk buttons (talk / answer). Every talk/answer press feeds one
utterance pipeline that logs an entry to `.studiorunner.d/memos.md` with
a full-screen screenshot and a DAW audio clip; the AI consolidates the
stream into `studiorunner.md`:

- **Talk button**: hold + speak → logged as above. If the transcript
  contains the wake word "Runner" (`Config.wakeWord`), the AI also
  answers from the current state; the exchange is appended to
  `.studiorunner.d/chat.md`, the answer is logged into memos.md with
  `Studio Runner:` attribution, and spoken via `AVSpeechSynthesizer`.
- **Answer button**: hold + speak → same, but always answered — no wake
  word needed. A silent tap (no speech) answers the last utterance if it
  went unanswered, otherwise re-speaks the last answer.

Pressing either button while TTS is speaking interrupts it (the press-down
handler calls `Speaker.stop()`): the producer's voice takes priority, and
it limits how much of the assistant's own speech leaks into the mic ring —
there is no echo cancellation.

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
| `SettingsWindow.swift` | Modeless `NSWindow` with fields for API key, language, TTS voice, TTS volume, mic device, DAW device, MIDI controller, and MTC source. Writes through to the corresponding `Config.set*` functions, which persist to the `.studiorunner` project file. |
| `SessionState.swift` | State enum (`idle`, `learningMemo`, `recordingMemo`, `processingMemo`, `recordingAsk`, `askThinking`, `askSpeaking`, `consolidating`, `notReady`, `error`). Drives the icon. |
| `Config.swift` | Single source of truth for all tunables. User-facing settings live in `ProjectSettings` (serialised as `<name>.studiorunner` at the project root). The app does not remember the last project across launches — it either prompts on launch or opens whatever `.studiorunner` file was double-clicked. |
| `ProjectSettings.swift` | Codable struct persisted as a `.studiorunner` JSON file. Holds API key, language, TTS voice/volume, mic/DAW/MIDI device names, MTC source, AI endpoint/model, and learned MIDI bindings. A global fallback copy in `~/Library/Application Support/StudioRunner/settings.json` seeds brand-new projects. |
| `Layout.swift` | Ensures the project-root directory layout (`studiorunner.md`, `.studiorunner.d/...`). |
| `MIDI.swift` | CoreMIDI client, learn flow (single press + release cycle), push-to-talk gate, MTC quarter-frame assembler. Learned bindings are persisted inside the `.studiorunner` project file via `MIDIBindingsStore` → `Config.setMidiBindings`. |
| `CoreAudioDevice.swift` | Finds a CoreAudio input device by display name and enumerates all available inputs for the settings popup. |
| `RollingBuffer.swift` | Fixed-size in-memory PCM ring; extraction derives wall-clock window from how many bytes are in the ring. |
| `MicRecorder.swift` | `AVCaptureSession` on the chosen input device → fresh `AVAudioConverter` per CMSampleBuffer chunk → 16 kHz mono Int16 → append to ring (with gain). Uses AVCaptureSession rather than AVAudioEngine because on macOS Sequoia the AVAudioEngine input tap silently delivers no data without a complete output graph. |
| `DAWRecorder.swift` | AVAudioEngine on a specific input device (`AudioUnitSetProperty(CurrentDevice)`) → 44.1 kHz stereo Int16 ring. |
| `WAVWriter.swift` | Minimal RIFF/WAVE header writer for trimmed clips. |
| `Whisper.swift` | `Process` invocation of `whisper-cli` (whisper.cpp). |
| `Screenshot.swift` | `Process` invocation of `screencapture -x`. |
| `AIClient.swift` | URLSession POST to any Anthropic-compatible Messages endpoint (DeepSeek by default, Claude, local proxy…); assembles the three-layer system prompt. |
| `Speak.swift` | AVSpeechSynthesizer wrapper for the spoken reply. |
| `MemoStream.swift` | Append / parse / watermark / prune of `.studiorunner.d/memos.md`. Entries carry a speaker label (`The Producer:` / `Studio Runner:`). |
| `UtteranceFlow.swift` | Per-press pipeline for both buttons: extract mic → transcribe → screenshot → DAW clip → append raw entry → if addressed (wake word or answer button) AI call with state + memo tail → append chat + assistant memo entry → speak → execute tags → schedule consolidation. |
| `Consolidator.swift` | Serial, debounced actor that rewrites `studiorunner.md` from the post-watermark slice and advances the watermark. |
| `Timestamps.swift` | YYMMDDHHMMSS and YY-MM-DD HH:MM:SS formatters. |

## Dependencies (at runtime)

| Dependency | Why |
|---|---|
| `whisper-cli` (Homebrew `whisper-cpp`) | Local speech-to-text. The bundle inherits the system PATH minus `/opt/homebrew/bin`, so `Config.whisperBinary` probes the usual Homebrew locations directly. |
| `ggml-medium.en.bin` model | Whisper model, ~1.5 GB at `~/Library/Application Support/StudioRunner/models/`. Auto-downloaded from Hugging Face on first launch if missing; lives outside `/opt/homebrew/` so `brew cleanup` can't wipe it. The multilingual `ggml-medium.bin` is fetched on demand when the language is set to anything other than English. |
| `screencapture` (macOS built-in) | Full-screen screenshots. |
| BlackHole 2ch (or any virtual loopback) | Optional. If the named CoreAudio input device is missing, DAW capture is skipped and a warning is logged. |
| AI API key | Consolidation + Q&A. Any Anthropic-compatible endpoint (DeepSeek is the default). Required. |

No Swift packages are pulled in — everything is Apple-provided
(AppKit, AVFoundation, CoreAudio, CoreMIDI, Foundation).

## Configuration

All user-facing settings are stored in the `<name>.studiorunner` JSON file at
the project root and edited through the Settings window (⌘,). There are no
`.env` files or environment variable overrides.

The app does not remember the last project across launches. On a plain
launch it shows the "No project" prompt (New / Open). Double-clicking a
`.studiorunner` file in Finder opens that project directly via
`application(_:open:)`.

Three constants in `Config.swift` can only be changed by editing the source:
- `Config.micGainDb` (25 dB): gain applied to the mic ring after conversion.
- `Config.pruneAssets` (false): set to `true` to delete audio + screenshots
  after consolidation.
- `Config.wakeWord` ("Runner"): saying this name in an utterance marks it
  as addressed to the assistant and triggers a spoken answer.

`aiEndpoint` and `aiModel` can be overridden per-project by editing the
`.studiorunner` file directly (e.g. to point at Claude or a local proxy).

## Output structure

`.studiorunner.d/` is hidden so it doesn't crowd the DAW session folder.
The `.studiorunner` project file travels with the DAW session and can be
opened from Finder to switch projects.

```
<projectRoot>/
  <name>.studiorunner          ← project settings + learned MIDI bindings (JSON)
  studiorunner.md              ← consolidated state — read this
  .studiorunner.d/
    system.md                  ← per-project context, prepended to every AI system prompt
    memos.md                   ← append-only memo stream, with watermark
    chat.md                    ← Q&A transcript
    screenshots/
      YYMMDDHHMMSS.png         ← screenshot per memo utterance
    audio/
      YYMMDDHHMMSS.wav         ← DAW clip per memo utterance (CD quality)
```

## Key design decisions

- **One menu bar app, no daemon, no IPC.** All the long-lived state
  (MIDI, audio rings, AI client, consolidation worker) lives
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
  bindings are saved inside the `.studiorunner` project file; the next
  session goes straight to listening. "Re-learn buttons…" in the menu
  clears them and triggers the learn flow again.
- **AVCaptureSession for mic, AVAudioEngine for DAW.** No `sox`
  subprocesses, no raw temp files on disk. `MicRecorder` uses
  `AVCaptureSession` (AVAudioEngine's input tap silently delivers no
  data on macOS Sequoia without a complete output graph). `DAWRecorder`
  uses `AVAudioEngine` with `kAudioOutputUnitProperty_CurrentDevice`
  overridden to BlackHole. Both rings live in memory at fixed capacity.
  The `AVAudioConverter` inside `MicRecorder` is created fresh per
  CMSampleBuffer chunk — reusing it causes zero output after the first
  chunk due to internal SRC state.
- **In-memory ring buffer with wall-clock-aware extraction.** Same
  insight as the bun script: don't trust spawn-time timestamps — derive
  the wall-clock time of the oldest byte from `now − bytesInRing /
  bytesPerSecond`. This self-corrects for tap-thread jitter.
- **One utterance pipeline, addressed-or-not decided after the fact.**
  Both buttons run the identical capture path; whether the AI answers is
  decided from the transcript (wake word) or the button used, never by
  forcing the producer to pre-classify a thought as "memo" vs "ask".
  The wake word is matched with a case-insensitive word-boundary regex —
  deterministic, no AI intent-classification call, so a plain memo costs
  no extra latency or tokens and the assistant can never speak
  unprompted over monitoring or a take.
- **Utterance flow writes memos.md *first*, then the AI.** A crash or
  network failure during answering or consolidation can never lose a
  note.
- **Answers feed back into the memo stream.** The spoken reply is
  appended to memos.md as a `Studio Runner:` entry, so consolidation can
  resolve Open questions from it. The consolidator prompt marks producer
  lines as authoritative and forbids deriving TODOs or track facts from
  assistant lines alone, guarding against the AI re-ingesting its own
  speculation as fact. chat.md keeps the verbatim exchange (including
  action tags).
- **Three-layer system prompt** assembled inside `AIClient.call(...)`:
  1. `Config.baseRole` — hardcoded persona, always present.
  2. `.studiorunner.d/system.md` — per-project user-edited context.
  3. Call-specific prompt — consolidation format rules, or the ask
     flow's "use the context, say so if it's missing" guidance.
  Joined with `\n\n---\n\n`. `studiorunner.md` is NOT in the system
  prompt — it lives in the user message because it's dynamic state.
- **Speaker label in memo entries.** Producer utterances are logged as
  `The Producer: <text>`, assistant answers as `Studio Runner: <text>`.
  (The label predates the answer-logging: an earlier flow had a parallel
  `DAW: <text>` line carrying whisper's transcription of the DAW clip,
  removed because hallucinations on near-silent loopback audio outweighed
  the value. The DAW clip itself is still captured and linked from the
  entry's `audio:` field for on-demand playback.)
- **Anthropic Messages protocol, not OpenAI-style.** The client speaks
  `x-api-key` + `anthropic-version: 2023-06-01` to whatever endpoint
  `aiEndpoint` names (default: DeepSeek's `/anthropic/v1/messages`) —
  kept consistent with the user's other tooling. Any provider that
  implements the Anthropic Messages protocol works.
- **TTS via AVSpeechSynthesizer**, not `say` + `afplay`. Volume is set
  directly on `AVSpeechUtterance.volume` (0.0–1.0), bypassing the
  modern macOS voices' silent ignore of inline `[[volm]]` directives.
- **No `Process` spawning except for two specific binaries**:
  `whisper-cli` and `screencapture`. They're independent native tools
  that the bun script also called out to; rewriting whisper.cpp
  bindings in Swift would multiply the build complexity without
  changing the architecture.
- **Graceful DAW degradation.** If no DAW device is configured or the
  named device isn't found, the DAW recorder is skipped and one warning
  is logged. The mic + assistant continue working without DAW capture.
  If MIDI has no sources, `MIDIClient.openAllSources` throws and the
  state goes to `.error` — push-to-talk is the only input method, so
  the session can't start without it.
- **Privacy prompts**: NSMicrophoneUsageDescription is in `Info.plist`
  so `AVCaptureSession.startRunning` triggers the macOS prompt on first
  run. `screencapture` needs Screen Recording permission granted manually
  in System Settings the first time. The entitlements file declares
  `audio-input`, `network.client`, and `files.user-selected.read-write`
  to keep the hardened runtime happy after Developer ID signing.
- **`.studiorunner` Finder icon**: every save sets the FinderInfo
  `kHasCustomIcon` bit on the file (`ProjectSettings.markHasCustomIcon`
  writes the 32-byte `com.apple.FinderInfo` xattr with bit 10 set).
  Without it, Finder's text thumbnailer renders the JSON body as a
  content-preview thumbnail that wins over `CFBundleDocumentTypes` →
  `StudioRunnerDoc.icns` — regardless of `UTTypeConformsTo` declarations
  or a shipping `QLThumbnailProvider` extension. The flag tells Finder
  "skip thumbnailing, use the type icon" and Finder falls back to our
  `.icns`. The file content is unmodified plain JSON. An app icon
  (`CFBundleIconFile=StudioRunner`) is also declared so NSAlert dialogs
  get the mug instead of the generic-app grid placeholder.

## Manual steps the user handles

- Re-sign with a Developer ID certificate (see `build.sh`'s comments).
- Grant Microphone + Screen Recording permissions on first launch.
- Optionally add `/Applications/StudioRunner.app` to Login Items.
  `build.sh` mirrors the freshly built bundle into `/Applications` by
  default (override with `STUDIO_INSTALL_DIR=...`, opt out with
  `STUDIO_SKIP_APPLICATIONS=1`).
- Set the API key in Settings (menu bar icon → Settings…, or ⌘,).
