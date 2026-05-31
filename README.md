# studio-runner

Voice-to-memo listener for DAW production sessions.

Speak your thoughts while working and studio-runner transcribes them, takes a screenshot, and appends everything to a timestamped session memo — so you never lose a production decision or creative idea.

## How it works

1. Waits silently until you speak (VAD threshold at −50 dB RMS, 0.3s trigger)
2. Records continuously until 3s of silence — one clean utterance per capture
3. Transcribes via whisper-cpp on the GPU (large-v3-turbo model, Apple Silicon)
4. Captures a full-screen screenshot
5. **Captures the DAW audio**: in parallel, a second sox process records your DAW output from a virtual loopback device (BlackHole 2ch) at CD quality. Each memo entry includes a WAV with the 10 seconds (configurable) before you started talking through to the end of your utterance.
6. Appends a timestamped entry to `memos/YYYY-MM-DD.md`

Everything runs locally — no API keys, no internet, no data leaves your machine.

## Requirements

- macOS with Apple Silicon
- [Bun](https://bun.sh)
- `brew install sox whisper-cpp blackhole-2ch`
- whisper model: `ggml-large-v3-turbo-q5_0.bin` at `/opt/homebrew/share/whisper-cpp/models/`

  ```bash
  whisper-cpp-download-ggml-model large-v3-turbo-q5_0
  ```

### One-time DAW routing setup

To capture DAW audio alongside your voice notes, route DAW output to BlackHole:

1. Open **Audio MIDI Setup** (`/System/Applications/Utilities`)
2. Click `+` → **Create Multi-Output Device**
3. Tick both your speakers/interface AND **BlackHole 2ch**
4. In your DAW, set the output to that Multi-Output Device

You'll keep hearing audio through your speakers, but BlackHole now receives a copy that studio-runner can record. If you skip this setup or set `STUDIO_DAW_DEVICE=""`, studio-runner falls back to mic + screenshot only.

## Quick start

```bash
cd /path/to/your/daw-project
STUDIO_PROJECT_ROOT=$(pwd) bun run /path/to/studio-runner/listen.ts
```

Speak your comments while working. Press Ctrl+C to stop.

## Claude Code integration

Add to `~/.claude/mcp.json`:

```json
{
  "mcpServers": {
    "studio-runner": {
      "command": "bun",
      "args": ["studio-runner.ts"],
      "cwd": "/path/to/studio-runner",
      "env": {
        "STUDIO_PROJECT_ROOT": "/path/to/your/daw-project"
      }
    }
  }
}
```

Claude can then call `check_speech` to retrieve spoken comments, `get_memo` to read the full session log, `get_status` to check listener state, and `take_screenshot` for manual captures.

## Resuming after restart

1. **Check it's running**: ask "is the studio-runner listening?" — Claude calls `get_status`
2. **Start listening** (if stopped): ask Claude to call `start_listening`
3. **Check what you said**: ask "what did I say?" — Claude calls `check_speech`

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STUDIO_PROJECT_ROOT` | current directory | Where `memos/` is created |
| `WHISPER_MODEL` | `…/ggml-large-v3-turbo-q5_0.bin` | Alternative model path |
| `WHISPER_LANG` | `en` | Language code (`nl` for Dutch) |
| `STUDIO_VAD_THRESHOLD` | `-50` | RMS dB threshold for voice activity detection |
| `STUDIO_MIC_GAIN` | `25` | Microphone gain in dB applied before VAD |
| `STUDIO_DAW_DEVICE` | `BlackHole 2ch` | CoreAudio input device for DAW capture. Set to `""` to disable. |
| `STUDIO_DAW_PREROLL` | `10` | Seconds of DAW audio retained before each utterance |

## Output structure

```
<STUDIO_PROJECT_ROOT>/
  memos/
    YYYY-MM-DD.md          ← running memo
    screenshots/
      YYMMDDHHMMSS.png     ← timestamped captures
    audio/
      YYMMDDHHMMSS.wav     ← DAW audio clip per utterance (CD quality)
```
