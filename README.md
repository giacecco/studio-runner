# Studio Runner

A native macOS menu bar app that turns two MIDI buttons into a
voice-driven production assistant.

- **Hold the memo button** + speak → your note is transcribed (locally,
  via whisper.cpp), a full-screen screenshot of the DAW is taken, the
  last 10 s of DAW audio is captured, and the whole thing is
  consolidated by an AI into a live track-state markdown
  (`studiorunner.md`). If your DAW is transmitting MTC, each entry is
  tagged with its DAW timeline position (e.g. `2:03`) so you can
  navigate the log by where you were in the session.
- **Hold the ask button** + speak → the AI answers a question against
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
- Optional: IAC Driver enabled (built into macOS) for DAW timeline
  position via MTC. See [DAW timeline position (MTC)](#daw-timeline-position-mtc) below.
- A MIDI controller with two buttons / pads / pedals.
- An Anthropic-compatible API key (`STUDIORUNNER_AI_API_KEY`).

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

Open **Settings** (menu bar icon → Settings…, or ⌘,) and paste your key into
the API key field. The menu bar item shows "Not ready" until the key is saved.

The key is stored inside the project file (ending in `.studiorunner`) alongside all other
settings.

## Project layout once a session has run

```
<your music project>/
  <name>.studiorunner          ← project settings (API key, devices, MIDI bindings…)
  studiorunner.md              ← read this; consolidated state
  .studiorunner.d/
    system.md                  ← edit this; per-project context for the AI
    raw.md                     ← append-only stream with watermark
    chat.md                    ← Q&A transcript
    screenshots/YYMMDDHHMMSS.png
    audio/YYMMDDHHMMSS.wav     ← DAW clips, CD quality
```

## DAW timeline position (MTC)

When your DAW transmits MTC (MIDI Timecode), Studio Runner snaps the playhead
position at the moment you press the memo button and records it alongside the
note. The session timeline in `studiorunner.md` then reads like:

```
- 2:03 — Recording something else again ([audio](…) · [screenshot](…), 26-06-06 10:34)
```

### 1 — Enable the IAC Driver

Open **Audio MIDI Setup** (Spotlight → "Audio MIDI Setup"), choose
**Window → Show MIDI Studio**, double-click **IAC Driver**, and tick
**Device is online**. This creates a virtual MIDI loopback bus on your Mac.

### 2 — Configure your DAW to send MTC on the IAC Driver

| DAW | Where to find it |
|---|---|
| **Logic Pro** | File → Project Settings → Synchronisation → MIDI → Transmit MTC → IAC Driver |
| **Ableton Live** | Preferences → Link/Tempo/MIDI → MIDI ports → enable Sync output for IAC Driver |
| **Reaper** | Preferences → Audio → MIDI Devices → enable MTC send on IAC Driver |
| **Pro Tools** | Setup → Peripherals → Synchronisation → MTC Generator Port → IAC Driver |

### 3 — Select the source in Studio Runner Settings

Open **Settings → MTC source** and pick **IAC Driver Bus 1**. Leave it on
**Any** if IAC is the only source sending timecode.

The DAW must be in playback (not paused) when you press the memo button — MTC
is only transmitted while the transport is running.

## Why a menu bar app and not a VST3 / AU plugin?

A plugin is a guest inside the DAW's audio process. The host owns the
CoreAudio session — it opens the device, sets the sample rate and buffer
size, and hands the plugin pre-routed buffers. A plugin has no authority
to open a separate `AVAudioEngine` session on the mic device independently;
the DAW already holds that handle.

You can technically call CoreAudio APIs from an in-process AU (v2) or
VST3 on macOS (they are not sandboxed the way AUv3 XPC extensions are),
but you would be fighting the host for device ownership. In practice this
causes dropped buffers, sample-rate conflicts, or crashes — and every DAW
handles the collision differently. If you wanted the mic signal through a
plugin you would need the user to route a mic input track to the plugin's
bus, which means the DAW decides which physical mic, at what gain, through
what insert chain. MIDI would similarly only arrive through the host's MIDI
graph, not an independent `MIDIClientCreate` session, so push-to-talk in
its current form would not be possible.

Running outside the DAW is the architectural advantage. StudioRunner opens
its own audio sessions independently of whatever Logic or Ableton is doing:
`MicRecorder` uses `AVCaptureSession` on the chosen input, `DAWRecorder`
uses `AVAudioEngine` on BlackHole. The DAW never knows StudioRunner is
listening. CoreMIDI broadcasts to all listeners simultaneously, so the DAW
and StudioRunner both receive the pedal press without conflict and without any
Accessibility-permission dance that a global keyboard shortcut would need.

## See also

`CLAUDE.md` for the full architecture overview and the design decisions
baked into the port from the previous Bun script.
