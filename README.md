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
  reply back through the system voice. If the question is about a
  specific note the AI can jump the DAW transport to that position —
  "take me to where I mentioned Vocalign."

No Dock icon, no terminal session — just a status item that changes
glyph while you're holding a button.

## Requirements

- macOS 13 or later, Apple Silicon.
- Xcode command-line tools (`swift`, `codesign`).
- Homebrew packages: `whisper-cpp`. The model file (`ggml-medium.en.bin`
  for English, `ggml-medium.bin` for everything else, ~1.5 GB each) is
  downloaded automatically by the app on first launch into
  `~/Library/Application Support/StudioRunner/models/`.
- **BlackHole 2ch** (or any virtual loopback) routed from your DAW —
  required for DAW audio clips in memo entries. Without it every memo
  captures a screenshot and transcription but no audio.
- **IAC Driver** enabled (built into macOS, off by default) — required
  for DAW timeline position tags in memo entries. See
  [DAW timeline position (MTC)](#daw-timeline-position-mtc) below.
- A MIDI controller with two buttons / pads / pedals.
- An Anthropic-compatible API key (entered in Settings, stored in the project file).

## Quick start

```bash
brew install whisper-cpp

# Build and launch
./build.sh
open .build/StudioRunner.app
```

The app downloads the Whisper model itself on first launch — it asks for
confirmation, then shows progress in the menu bar.

The first launch will:

1. Show a Microphone permission prompt — grant it.
2. Need Screen Recording granted manually the first time a memo
   triggers a screenshot — System Settings → Privacy & Security →
   Screen Recording, add StudioRunner.app, then quit and relaunch.
3. Show a "No project" dialog with **New project…** and **Open
   existing…** — pick one. The `.studiorunner` file lives at the root
   of the folder you choose, `studiorunner.md` next to it, and the rest
   under `.studiorunner.d/`. After this, you can also launch a project
   directly by double-clicking its `.studiorunner` file in Finder — the
   app does not remember the last project across launches.
4. Ask you to press each button in turn (memo first, then ask). The
   bindings persist across launches.

## API key

Open **Settings** (menu bar icon → Settings…, or ⌘,) and paste your key into
the API key field. The menu bar item shows "Not ready" until the key is saved.

The key is stored inside the project file (ending in `.studiorunner`) alongside all other
settings.

## Language

Studio Runner defaults to English. To work in another language, open
**Settings → Session language** and pick from the list (French, German,
Spanish, Italian, Dutch, Portuguese, Japanese, Korean, Chinese).

Changing the language does three things at once:

- **Transcription** — Whisper is told which language to expect, improving
  accuracy. Non-English sessions use the multilingual model
  (`ggml-medium.bin`) instead of the English-only one; the app prompts to
  download it the first time you switch to a non-English language.
- **AI replies** — the assistant is instructed to write everything
  (notes, consolidated state, Q&A) in the chosen language.
- **TTS voice** — the voice picker in Settings is filtered to voices that
  match the selected language, so the spoken reply sounds natural.

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

## Ask flow — voice commands

Studio Runner is a junior assistant for *this* session — it knows what you
said, when you said it, and where in the timeline you said it. It is not a
production advisor. For production advice, go to a real expert human
producer.

During an ask session the AI answers questions against the current session
state, but it can also trigger actions. Speak naturally — exact phrasing
does not matter.

| What to say | What happens |
|---|---|
| "Play the recording from when I noticed the reverb" | Plays the DAW audio clip associated with that note after the AI finishes speaking |
| "Show me the screenshot from bar 32" | Opens the screenshot from that note in Preview |
| "Take me to where I mentioned Vocalign" / "Go to the last note about the kick" | Stops the DAW transport (if running) and moves the playhead to the `daw_pos` timestamp recorded with that note. Requires MTC to have been active when the memo was taken. |
| "Clear the session" / "Reset" / "Wipe the session" | Resets the session timeline, raw stream, chat history, and all audio/screenshots. Track notes, TODOs, and open questions are kept. Asks you to confirm in speech before executing. |

Actions are extracted from the AI response as tagged directives
(`[PLAY: …]`, `[SHOW: …]`, `[GOTO: M:SS]`, `[CLEAR_SESSION]`) and
executed after TTS finishes — you hear the reply first, then the clip
plays, the screenshot opens, or the playhead jumps. File paths and
positions are never spoken aloud.

If the AI cannot find a matching recording, screenshot, or timeline
position it will say so rather than guessing.

### Transport navigation via GOTO

When you ask to navigate to a note, StudioRunner sends three MIDI CCs on its
virtual source (channel 16) to the Bitwig controller script:

| CC | Carries |
|---|---|
| 116 | minutes (0–127) |
| 115 | seconds (0–59) |
| 114 value=127 | trigger: stop transport + jump to position |

The script converts wall-clock time to beats using the current project BPM.
This is exact for constant-tempo projects; for variable-tempo projects the
cursor lands in the right neighbourhood but may be off by a bar or two.

MTC must have been transmitting when the original memo was taken — if no
`daw_pos` was recorded for a note, the AI will say so instead of guessing.

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

## Bitwig: suspend transport while speaking

A single Bitwig controller script in `tools/bitwig-suspend/` pauses the
Bitwig transport when you press a button and resumes it when you release
(memo) or when StudioRunner finishes responding (ask — after transcription,
AI reply, TTS, and any clip playback).

If the transport was already stopped when you pressed a button, it stays
stopped — the script only resumes what it paused.

### How it works

**StudioRunner Transport** listens on two MIDI inputs:

- **Grid** (port 0) — press/release events. On press while transport is
  playing: saves playhead position and stops. Memo resumes on release; ask
  waits for a done signal.
- **StudioRunner** (port 1) — a virtual MIDI source the app creates at
  startup. Two signal types arrive here on channel 16:
  - **CC 119 value=127** — ask flow done; resume transport after 1 s.
  - **CC 116/115/114** — GOTO sequence (minutes, seconds, trigger); stop
    transport and jump playhead to that position.

### Setup

**1 — Symlink the script into Bitwig's controller folder**

```bash
ln -s "$(pwd)/tools/bitwig-suspend/StudioRunnerTransport.control.js" \
  ~/Documents/Bitwig\ Studio/Controller\ Scripts/
```

**2 — Launch StudioRunner first**

The virtual MIDI ports (`StudioRunner` source and destination) only exist
while the app is running. Bitwig must see them when it loads the script.

**3 — Add the controller in Bitwig**

Dashboard → Settings → Controllers → Add Controller → search "StudioRunner
Transport". Configure the three ports:

| Port | Device |
|---|---|
| Input 1 | Intech Studio: Grid |
| Input 2 | StudioRunner |
| Output | IAC Driver Bus 1 |

IAC Driver Bus 1 as output is a dummy — nothing is sent on it. It is only
required because Bitwig needs an output port to enable a controller script.

**4 — Reload order matters**

If you restart Bitwig before StudioRunner is running, the StudioRunner
ports won't be found. Fix: with StudioRunner already open, go to the
Controllers page and disable then re-enable the script.

### Changing the MIDI buttons

The script is hard-coded to CC 44 (memo) and CC 45 (ask) on the Intech
Studio: Grid. If you re-learn the bindings in StudioRunner, update those
values in `StudioRunnerTransport.control.js` and reload the script in Bitwig.

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
