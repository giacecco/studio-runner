# studio-runner

Voice-to-memo listener for DAW production sessions.

Speak your thoughts while working and studio-runner transcribes them, takes a screenshot, and appends everything to a timestamped session memo — so you never lose a production decision or creative idea.

## How it works

1. Waits silently until you speak (VAD threshold at −50 dB RMS, 0.3s trigger)
2. Records continuously until 3s of silence — one clean utterance per capture
3. Transcribes via whisper-cpp on the GPU (large-v3-turbo model, Apple Silicon)
4. Captures a full-screen screenshot
5. Appends a timestamped entry to `memos/YYYY-MM-DD.md`

Everything runs locally — no API keys, no internet, no data leaves your machine.

## Requirements

- macOS with Apple Silicon
- [Bun](https://bun.sh)
- `brew install sox whisper-cpp`
- whisper model: `ggml-large-v3-turbo-q5_0.bin` at `/opt/homebrew/share/whisper-cpp/models/`

  ```bash
  whisper-cpp-download-ggml-model large-v3-turbo-q5_0
  ```

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

## Output structure

```
<STUDIO_PROJECT_ROOT>/
  memos/
    YYYY-MM-DD.md          ← running memo
    screenshots/
      YYMMDDHHMMSS.png     ← timestamped captures
```
