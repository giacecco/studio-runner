# CLAUDE.md — studio-runner

Voice-to-memo listener for music production sessions. Records from the mic, transcribes via whisper-cpp (local), captures full-screen screenshots, and appends to a dated Markdown memo file.

## Architecture

- **`studio-runner.ts`** — core library + MCP server. When run directly (`bun run studio-runner.ts`), starts the MCP server for Claude Code. When imported, exposes the core functions (`startListening`, `stopListening`, `transcribe`, etc.).
- **`listen.ts`** — thin standalone CLI wrapper. Imports from `studio-runner.ts`. Run via `bun run listen.ts`.

## Dependencies

| Dependency | Purpose |
|---|---|
| `sox` (Homebrew) | Microphone capture, silence detection |
| `whisper-cpp` (Homebrew) | Local speech-to-text via Metal on Apple Silicon |
| `ggml-large-v3-turbo-q5_0.bin` model | ~550 MB, at `/opt/homebrew/share/whisper-cpp/models/` |
| `screencapture` (macOS built-in) | Full-screen screenshots |
| `bun` | TypeScript runtime |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STUDIO_PROJECT_ROOT` | `cwd` | Where `memos/` directory is created |
| `WHISPER_MODEL` | `/opt/homebrew/share/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin` | Model path |
| `WHISPER_LANG` | `en` | Language code; set to `nl` for Dutch |
| `STUDIO_VAD_THRESHOLD` | `−50` | RMS dB threshold for voice activity detection |
| `STUDIO_MIC_GAIN` | `25` | Microphone gain in dB applied before VAD |
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

- **Continuous sox recording**: Each iteration calls sox once with its native `silence` filter — `silence 1 0.3 -50d 1 3.0 -50d`. Sox blocks until 0.3s of speech above −50 dB is detected, records until 3s of silence, then exits. One clean utterance WAV per iteration, no chunk stitching, no inter-recording gaps.
- **Subprocess control via `Bun.spawn`**: Used instead of the `$` template tag so the sox process handle is available for `.kill()` on stop or hard cap.
- **Max utterance cap**: Auto-kills sox after 30s of continuous speech to bound file size.
- **Deduplication**: Consecutive identical transcriptions are suppressed. A genuine duplicate resets the guard so the same phrase can reappear after a pause.
- **Screenshots taken after utterance ends**: Screenshot is captured once sox exits and the text is confirmed non-empty, immediately before appending to the memo.
- **No audio files saved**: Temporary WAVs are deleted after transcription. Memos contain only text and screenshots.
- **Metal GPU**: whisper-cpp runs on the M2 Max GPU via `whisper-cli -t 6`. First invocation after cold boot compiles the Metal library (~10s); subsequent runs are fast.
- **No-speech suppression**: `--no-speech-thold 0.5` tells whisper to return empty output (rather than hallucinate) when the no-speech probability exceeds 0.5.
- **DAW capture (parallel recorder)**: A second sox process records the DAW output from a virtual loopback device (`STUDIO_DAW_DEVICE`, default `BlackHole 2ch`) into `/tmp/studio-runner-daw-rolling.wav` at CD quality (44.1 kHz / 16-bit / stereo). Captured via `-t coreaudio "<device>"`.
- **Pre-roll + reset-per-utterance**: On each utterance, `extractDawClip` runs `sox … trim` over the window `[speech_start − STUDIO_DAW_PREROLL, speech_end]` (clamped to what's actually in the rolling file) and writes `memos/audio/YYMMDDHHMMSS.wav`. Then `resetDawRecorder` kills sox, deletes the rolling file, and spawns a fresh recorder. This bounds disk usage to "time since last utterance" — typically a few MB.
- **Speech-start timestamp**: The memo timestamp is derived from `utteranceEndMs − soxiDurationSec`, so entries are anchored to when the user *started* speaking. The DAW clip is named with the same timestamp.
- **Graceful degradation**: If `STUDIO_DAW_DEVICE` is missing or empty, the DAW recorder either fails fast at spawn (watchdog at 1s) or is skipped entirely. The mic listener continues without DAW capture; a single warning is logged.
