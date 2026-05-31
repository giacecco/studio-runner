# studio-runner

Voice-driven companion for music production sessions.

Two MIDI buttons. Hold one to speak a note — studio-runner transcribes
it, captures a screenshot, records the DAW audio that was playing under
it, and writes it all into a running session log. Hold the other to
**ask** a question — DeepSeek answers from a live, consolidated state of
the track, and reads the reply back via `say`.

## How it works

1. On startup, prompts you to bind two MIDI buttons: one for **memo**,
   one for **ask**. Any controller already on your CoreMIDI bus works
   (sustain pedal, an unused pad, the buttons on a transport panel).
2. Rolling mic + DAW recorders run continuously in raw PCM, so the audio
   devices are always hot — no cold-start latency eating your first
   words.
3. Hold **memo** → speak → release. The mic clip is extracted, whisper
   transcribes it locally on the GPU, a screenshot is taken, the
   matching slice of DAW audio is saved, and the entry is appended to
   `.studiorunner.d/raw.md`.
4. A background DeepSeek call distils the raw stream into a curated
   `studiorunner.md` with sections **TODO**, **Track notes**,
   **Open questions**, **Session timeline**.
5. Hold **ask** → speak → release. DeepSeek answers from the curated
   state plus any unconsolidated tail. The reply prints, appends to
   `.studiorunner.d/chat.md`, and is spoken back via `say`.

Whisper runs locally; DeepSeek runs in the cloud (Anthropic-compatible
endpoint). No screenshots or audio leave the machine.

## Requirements

- macOS with Apple Silicon
- [Bun](https://bun.sh)
- `brew install sox whisper-cpp blackhole-2ch`
- whisper model: `ggml-medium.en.bin` at
  `/opt/homebrew/share/whisper-cpp/models/`

  ```bash
  whisper-cpp-download-ggml-model medium.en
  ```
- A DeepSeek API key — `export STUDIORUNNER_AI_API_KEY=…` (the script
  refuses to start without it)
- A MIDI controller / pedal pair visible to CoreMIDI. Two distinct
  buttons; they can be on the same controller. The DAW can keep using
  the device — CoreMIDI broadcasts, so we tap it passively.

### One-time DAW routing setup

To capture DAW audio alongside your voice notes, route DAW output to
BlackHole:

1. Open **Audio MIDI Setup** (`/System/Applications/Utilities`)
2. Click `+` → **Create Multi-Output Device**
3. Tick both your speakers/interface AND **BlackHole 2ch**
4. In your DAW, set the output to that Multi-Output Device

You'll keep hearing audio through your speakers, but BlackHole now
receives a copy that studio-runner can record. If you skip this setup
or set `STUDIO_DAW_DEVICE=""`, studio-runner falls back to mic +
screenshot only.

## Quick start

```bash
cd /path/to/your/track-project
export STUDIORUNNER_AI_API_KEY=…
bun run /path/to/studio-runner/studio-runner.ts
```

You'll see:

```
Press and hold the button/pedal you want to use to leave a note...
```

Press, hold, release. Then the same prompt for **ask**. The two
bindings are reported back and remain the gates for the session.

From then on:

- **Memo**: hold, speak the note, release.
- **Ask**: hold, speak the question, release. Answer prints + plays.
- **Ctrl+C** to stop.

### Prune

When `studiorunner.md` has absorbed enough of the raw stream that you
trust dropping the source, run:

```bash
bun run /path/to/studio-runner/studio-runner.ts prune
```

That removes every raw entry up to the consolidation watermark.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STUDIORUNNER_AI_API_KEY` | — | **Required.** DeepSeek API key. Script refuses to start without it. |
| `STUDIO_DEEPSEEK_MODEL` | `deepseek-chat` | DeepSeek model id; `deepseek-reasoner` for slower / heavier reasoning |
| `STUDIO_PROJECT_ROOT` | current directory | Project folder where `studiorunner.md` lives |
| `STUDIO_NOTES_FILE` | `studiorunner.md` | Consolidated state filename |
| `STUDIO_RUNNER_DIR` | `.studiorunner.d` | Hidden directory for raw stream, chat log, audio, screenshots |
| `STUDIO_TTS` | `1` | `0` disables `say` playback of assistant replies |
| `STUDIO_TTS_VOICE` | unset | Passed through to `say -v` if set |
| `STUDIO_PRUNE_ASSETS` | `0` | `1` deletes audio + screenshot for each entry as it's consolidated |
| `WHISPER_MODEL` | `…/ggml-medium.en.bin` | Alternative whisper model path |
| `WHISPER_LANG` | `en` | Language code (`nl` for Dutch) |
| `STUDIO_MIC_GAIN` | `25` | Microphone gain in dB applied to the rolling mic buffer |
| `STUDIO_MIC_PREROLL` | `0.5` | Seconds of mic audio retained before each button-down |
| `STUDIO_MIC_POSTROLL` | `0.5` | Seconds of mic audio retained after each button-up |
| `STUDIO_DAW_DEVICE` | `BlackHole 2ch` | CoreAudio input device for DAW capture. `""` disables. |
| `STUDIO_DAW_PREROLL` | `10` | Seconds of DAW audio retained before each memo utterance |

## Output structure

```
<STUDIO_PROJECT_ROOT>/
  studiorunner.md            ← consolidated state — read this
  .studiorunner.d/
    raw.md                   ← append-only raw stream, with watermark
    chat.md                  ← Q&A transcript
    screenshots/
      YYMMDDHHMMSS.png       ← timestamped captures
    audio/
      YYMMDDHHMMSS.wav       ← DAW clip per memo utterance (CD quality)
```
