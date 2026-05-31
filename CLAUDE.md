# CLAUDE.md — studio-runner

Voice-to-memo listener for music production sessions. Push-to-talk via a user-chosen MIDI button/pedal; transcribes via whisper-cpp (local), captures full-screen screenshots, and appends to a dated Markdown memo file.

## Architecture

- **`studio-runner.ts`** — core library + MCP server. When run directly (`bun run studio-runner.ts`), starts the MCP server for Claude Code. When imported, exposes the core functions (`startListening`, `stopListening`, `transcribe`, etc.).
- **`listen.ts`** — thin standalone CLI wrapper. Imports from `studio-runner.ts`. Run via `bun run listen.ts`.

## Dependencies

| Dependency | Purpose |
|---|---|
| `sox` (Homebrew) | Microphone + DAW capture |
| `whisper-cpp` (Homebrew) | Local speech-to-text via Metal on Apple Silicon |
| `ggml-medium.en.bin` model | ~1.5 GB, at `/opt/homebrew/share/whisper-cpp/models/` |
| `screencapture` (macOS built-in) | Full-screen screenshots |
| `@julusian/midi` (npm) | CoreMIDI access for the push-to-talk gate |
| `bun` | TypeScript runtime |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STUDIO_PROJECT_ROOT` | `cwd` | Where `memos/` directory is created |
| `WHISPER_MODEL` | `/opt/homebrew/share/whisper-cpp/models/ggml-medium.en.bin` | Model path |
| `WHISPER_LANG` | `en` | Language code; set to `nl` for Dutch |
| `STUDIO_MIC_GAIN` | `25` | Microphone gain in dB applied to the rolling mic buffer |
| `STUDIO_MIC_PREROLL` | `0.5` | Seconds of mic audio retained before the button-down event |
| `STUDIO_MIC_POSTROLL` | `0.5` | Seconds of mic audio retained after the button-up event (catches the tail of the last syllable) |
| `STUDIO_DAW_DEVICE` | `BlackHole 2ch` | CoreAudio input device used for DAW capture. Set to `""` to disable. |
| `STUDIO_DAW_PREROLL` | `10` | Seconds of DAW audio retained before each utterance |

## Output structure

```
<STUDIO_PROJECT_ROOT>/
  memos/
    YYYY-MM-DD.md               ← running memo
    screenshots/
      YYMMDDHHMMSS.png           ← timestamped captures
    audio/
      YYMMDDHHMMSS.wav           ← DAW audio clip per utterance (CD quality)
```

## Configuration (Claude Code MCP)

In `~/.claude/.mcp.json`:

```json
{
  "mcpServers": {
    "studio-runner": {
      "command": "bun",
      "args": ["studio-runner.ts"],
      "cwd": "/Users/giacecco/Documents/Projects/studio-runner",
      "env": {
        "STUDIO_PROJECT_ROOT": "/Volumes/External/Music productions/Other/Til Kingdom Come 2026"
      }
    }
  }
}
```

## Key design decisions

- **MIDI push-to-talk**: Recording is gated by a MIDI message the user chooses at startup — `learnMidiBinding()` opens every CoreMIDI input port, prompts "Press and hold the button/pedal…", and binds to the first Note On (vel > 0) or CC (value ≥ 64) it sees. It then waits for the matching "up" before returning, so the session doesn't start mid-press. The binding is channel-aware (`{kind, channel, number, portName}`). No VAD, no silence filter, no max-utterance cap.
- **Why MIDI**: CoreMIDI broadcasts to every listener, so we tap whatever button/pedal the user already has within reach without stealing input from the DAW, and there's no Accessibility permission dance like a global keyboard hotkey would need.
- **Always-on mic rolling buffer**: A single sox process records the mic continuously into `/tmp/studio-runner-mic-rolling.raw` (16 kHz mono 16-bit). The button events only record timestamps (`pressStartMs`, `pressEndMs`); the worker later runs `sox … trim` over `[pressStart − STUDIO_MIC_PREROLL, pressEnd + STUDIO_MIC_POSTROLL]` to produce the per-utterance clip. This eliminates the 200–700 ms sox CoreAudio cold-start gap that would otherwise eat the first words, and the post-roll catches the tail of the last syllable when the release comes slightly before the user has finished speaking. The buffer is kept for the full session (no reset per utterance — that would race against the next press) and deleted on `stopListening`. At 32 KB/s mic usage is ~115 MB/hour.
- **Raw PCM rolling files (no WAV header)**: Both rolling buffers (`/tmp/studio-runner-mic-rolling.raw` at 16 kHz mono 16-bit, `/tmp/studio-runner-daw-rolling.raw` at 44.1 kHz stereo 16-bit) are written with `-e signed-integer -t raw`. WAV would clip the tail: sox doesn't finalise the RIFF size and `data` chunk size until close, so a `sox trim` against a still-recording WAV reads only up to whatever the stale header advertises and silently drops the rest. Raw has no header, so "what's readable" is simply "what's on disk".
- **File-size-derived recording start**: `extract{Mic,Daw}Clip` derives the rolling recording's wall-clock start from `statSync(path).size / bytesPerSec` at extraction time, not from `Date.now()` at sox spawn. This self-corrects for both sox's variable CoreAudio cold-start (200–700 ms) and the OS write-buffer lag (~250 ms), either of which would otherwise slide the trim offset off the real start of speech.
- **Flush wait + post-roll**: Before extraction, the worker sleeps 500 ms so sox can flush its write buffer. Combined with `STUDIO_MIC_POSTROLL` (default 0.5 s), this means the extraction window `[pressStart − 0.5, pressEnd + 0.5]` is reliably on disk by the time we run `sox trim`.
- **Event-driven mic gate**: The MIDI message handler filters for the bound message: down → set `pressActive` and record `pressStartMs`; up → push `{startMs, endMs}` onto the worker queue. A worker drains: extract mic clip, transcribe, screenshot, DAW clip, append memo, reset DAW recorder.
- **Subprocess control via `Bun.spawn`**: Used instead of the `$` template tag so the sox process handle is available for `.kill()` on release or stop.
- **Deduplication**: Consecutive identical transcriptions are suppressed. A genuine duplicate resets the guard so the same phrase can reappear after a pause.
- **Stop/start re-entrance**: `stopListening()` detaches the MIDI gate but keeps the port open, so the MCP `start_listening` tool can re-arm without re-learning. `shutdownMidi()` does the full close on process exit.
- **Screenshots taken after utterance ends**: Screenshot is captured once sox exits and the text is confirmed non-empty, immediately before appending to the memo.
- **No mic audio files saved**: Temporary WAVs are deleted after transcription. Memos contain text, screenshots, and DAW clips only.
- **Metal GPU**: whisper-cpp runs on the M2 Max GPU via `whisper-cli -t 6`. First invocation after cold boot compiles the Metal library (~10s); subsequent runs are fast.
- **No-speech suppression**: `--no-speech-thold 0.5` tells whisper to return empty output (rather than hallucinate) when the no-speech probability exceeds 0.5. `--no-fallback` additionally disables the temperature fallback, which was the dominant source of pattern hallucinations (e.g. "1 to 5" → "1 2 3 4 5 6 7 8 9 10") under heavy quantisation.
- **DAW capture (parallel recorder)**: A second sox process records the DAW output from a virtual loopback device (`STUDIO_DAW_DEVICE`, default `BlackHole 2ch`) into `/tmp/studio-runner-daw-rolling.wav` at CD quality (44.1 kHz / 16-bit / stereo). Captured via `-t coreaudio "<device>"`.
- **Pre-roll + reset-per-utterance**: On each utterance, `extractDawClip` runs `sox … trim` over the window `[speech_start − STUDIO_DAW_PREROLL, speech_end]` (clamped to what's actually in the rolling file) and writes `memos/audio/YYMMDDHHMMSS.wav`. Then `resetDawRecorder` kills sox, deletes the rolling file, and spawns a fresh recorder. This bounds disk usage to "time since last utterance" — typically a few MB.
- **Speech-start timestamp**: With push-to-talk we have a precise `micStartMs` from the down event, so the memo entry and DAW clip are both anchored to it directly — no `soxi` round-trip needed.
- **Graceful degradation**: If `STUDIO_DAW_DEVICE` is missing or empty, the DAW recorder either fails fast at spawn (watchdog at 1s) or is skipped entirely. The mic listener continues without DAW capture; a single warning is logged. If no MIDI input ports are present, `learnMidiBinding()` throws — push-to-talk is the only input method, so the session can't start without it.
