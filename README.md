# Studio Runner

A native macOS menu bar app that turns two MIDI buttons into a
voice-driven production assistant.

- **Hold the memo button** + speak → your note is transcribed (locally,
  via whisper.cpp), a full-screen screenshot of the DAW is taken, the
  last 10 s of DAW audio is captured, and the whole thing is
  consolidated by DeepSeek into a live track-state markdown
  (`studiorunner.md`).
- **Hold the ask button** + speak → DeepSeek answers a question against
  the current state, appends the exchange to `chat.md`, and reads the
  reply back through the system voice.

No Dock icon, no terminal session — just a status item that changes
glyph while you're holding a button.

## Requirements

- macOS 13 or later, Apple Silicon.
- Xcode command-line tools (`swift`, `codesign`).
- Homebrew packages: `whisper-cpp` (plus the `ggml-medium.en.bin` model).
- Optional: BlackHole 2ch (or any virtual loopback) routed from your
  DAW. Without it, only the mic and Q&A flow work — memo entries still
  capture screenshots, just no DAW audio clip.
- A MIDI controller with two buttons / pads / pedals.
- A DeepSeek API key (`STUDIORUNNER_AI_API_KEY`).

## Quick start

```bash
brew install whisper-cpp
# fetch the medium English model (~1.5 GB)
bash /opt/homebrew/share/whisper-cpp/models/download-ggml-model.sh medium.en

# Build and launch
./build.sh
open .build/StudioRunner.app
```

The first launch will:

1. Show a Microphone permission prompt — grant it.
2. Need Screen Recording granted manually the first time a memo
   triggers a screenshot — System Settings → Privacy & Security →
   Screen Recording, add StudioRunner.app, then quit and relaunch.
3. Ask you to pick a project folder (menu → "Choose project folder…").
   `studiorunner.md` will live at the root of that folder; the rest
   goes under `.studiorunner.d/`.
4. Ask you to press each button in turn (memo first, then ask). The
   bindings persist across launches.

## API key

Store the key in `~/Library/Application Support/StudioRunner/.env`:

```
STUDIORUNNER_AI_API_KEY=sk-…
```

Or export it in the shell that launches `open .build/StudioRunner.app`.
The menu bar item shows "Not ready" if the key is missing.

## Project layout once a session has run

```
<your music project>/
  studiorunner.md              ← read this; consolidated state
  .studiorunner.d/
    system.md                  ← edit this; per-project context for DeepSeek
    raw.md                     ← append-only stream with watermark
    chat.md                    ← Q&A transcript
    midi-bindings.json         ← learnt buttons
    screenshots/YYMMDDHHMMSS.png
    audio/YYMMDDHHMMSS.wav     ← DAW clips, CD quality
```

## See also

`CLAUDE.md` for the full architecture overview, the list of tunable
environment variables, and the design decisions baked into the port
from the previous Bun script.
