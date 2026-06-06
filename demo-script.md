# Studio Runner — Demo Script

A suggested sequence for filming a walkthrough of the main features.
Approximate runtime: 4–6 minutes of recorded material.

---

## Before you hit record

- Bitwig open with a track that has some audio — a song you can actually
  play and comment on. The transport should be stopped, positioned somewhere
  in the middle of the arrangement.
- StudioRunner launched; menu bar icon visible (idle state).
- MIDI controller in frame or at least its buttons visible/audible.
- Microphone set to a decent input level; no background noise.
- The project's `.studiorunner` file already exists so there's no first-run
  prompt during the take.
- `.studiorunner.d/raw.md` and `studiorunner.md` are empty (fresh session),
  so the timeline builds visibly during the demo.
- BlackHole (or your DAW loopback) active so DAW audio clips get captured.

---

## Scene 1 — App overview (30 s)

1. Click the menu bar icon to open the menu.
   - Point out: project path, session status, Settings…, Open Notes…
2. Close the menu. No further setup needed.

**Narration cue:** "StudioRunner lives in the menu bar. No windows, no
switching apps. You control it from your MIDI controller."

---

## Scene 2 — Start a session and record the first memo (60 s)

3. **Hold the session button.** Icon changes to the active state.
4. Start Bitwig playing.
5. **Hold the memo button + speak:**
   > "The lead vocal in the chorus needs a low-cut around 120 Hz — it's
   > fighting the kick."
6. Release the memo button. Bitwig pauses briefly while the clip is captured,
   then resumes.
7. **Hold memo + speak again** (a few bars later):
   > "Trying Vocalign to lock the backing vocal to the lead in the bridge.
   > It sounds tight but slightly mechanical — may need to dial the intensity
   > back."
8. Release.
9. **Hold memo + speak one more time:**
   > "Kick drum needs more attack. Boosted at 3 kHz with the channel EQ,
   > about 4 dB."
10. Release.

**What to show:** after each release, the menu bar icon briefly shows the
processing state (transcribing → consolidating), then returns to idle.

---

## Scene 3 — View the notes (20 s)

11. Click the menu bar icon → **Open Notes**.
    `studiorunner.md` opens in your default editor (e.g. Obsidian or Typora).
12. Scroll through the Session timeline section — the three entries are there,
    each with a `daw_pos` timestamp, a screenshot link, and an audio link.

**Narration cue:** "Every memo is transcribed, timestamped, and consolidated
into a readable session log automatically."

---

## Scene 4 — Ask a question (45 s)

13. Stop Bitwig playback. (The assistant answers over speakers; quieter is
    clearer on camera.)
14. **Hold the ask button + speak:**
    > "What was I doing with Vocalign?"
15. Release. Icon shows thinking → speaking states.
    The assistant answers verbally, e.g.:
    > "In the bridge you used Vocalign to align the backing vocal to the lead.
    > It sounded tight but slightly mechanical — you noted you might dial back
    > the intensity."

**What to show:** after the answer the DAW resumes (if it was playing when
you pressed ask — otherwise it stays stopped).

---

## Scene 5 — Navigate to a note (60 s) ← new feature

16. **Hold ask + speak:**
    > "Take me to where I took the note about Vocalign."
17. Release. The assistant answers verbally, e.g.:
    > "Going to 2:03, your Vocalign note in the bridge."
18. **Watch the Bitwig playhead jump** to the 2:03 position.
19. In Bitwig, zoom in to show the playhead is now at that exact bar.

**Narration cue:** "The timestamp in the note becomes a navigation target.
One voice command and Bitwig moves to that moment in the session."

---

## Scene 6 — Review a screenshot (20 s)

20. **Hold ask + speak:**
    > "Show me the screenshot from the Vocalign note."
21. Release. Preview opens with the full-screen screenshot from that moment.
22. Briefly show the screenshot (Bitwig visible in the background of the
    screen capture, confirming it was taken at the right time).

---

## Scene 7 — Play back the DAW clip (20 s)

23. **Hold ask + speak:**
    > "Play the audio from the Vocalign recording."
24. Release. The WAV clip plays back through your monitors — you can hear the
    DAW mix from that moment in the session.

---

## Scene 8 — Wrap up (20 s)

25. Click the menu bar icon → **Open Notes** one more time.
    Show `studiorunner.md` with all three entries, screenshot and audio links
    rendered as clickable references.
26. Release the session button. Icon returns to idle.

**Closing narration cue:** "Every note, screenshot, and audio clip is saved
in the project folder alongside the DAW session. The session log travels with
the project."

---

## Optional extras (cut if time is short)

- **Settings window** (⌘,): show the API key field, language selector, TTS
  voice picker, and device dropdowns.
- **Clear session**: ask "Clear the session" — the assistant confirms and
  the timeline resets.
- **Re-learn buttons**: Menu → Re-learn buttons… — walks through the
  three-button learn flow again.
- **Open Raw** (Menu → Open Raw): show `.studiorunner.d/raw.md` to
  demonstrate the append-only source of truth behind the consolidated notes.
