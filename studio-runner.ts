/**
 * studio-runner — voice-to-memo + DeepSeek-backed track-state assistant
 *
 * Single CLI. Two MIDI bindings learned at startup:
 *   - memo button: hold + speak → entry appended to .studiorunner.d/raw.md,
 *     DeepSeek consolidates into studiorunner.md
 *   - ask button:  hold + speak → DeepSeek answers from the current state,
 *     reply prints, appends to .studiorunner.d/chat.md, and is spoken via `say`
 *
 * Subcommand: `prune` drops already-consolidated raw entries.
 */

import { $ } from "bun";
import { Input as MidiInput } from "@julusian/midi";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

// Load .env from the script's directory before reading any env var. Bun's
// auto-load reads .env from process.cwd(), which here is the user's music
// project folder, not this repo — so the auto-load would miss the key.
(() => {
  const envPath = join(import.meta.dir, ".env");
  if (!existsSync(envPath)) return;
  try {
    const content = readFileSync(envPath, "utf-8");
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const eq = trimmed.indexOf("=");
      if (eq < 0) continue;
      const key = trimmed.slice(0, eq).trim();
      let value = trimmed.slice(eq + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      if (!(key in process.env)) process.env[key] = value;
    }
  } catch (err) {
    console.error(`failed to read ${envPath}:`, err);
  }
})();

// ── Configuration ────────────────────────────────────────────────────────

const PROJECT_ROOT = process.env.STUDIO_PROJECT_ROOT || process.cwd();
const RUNNER_DIR_NAME = process.env.STUDIO_RUNNER_DIR || ".studiorunner.d";
const NOTES_FILE = join(PROJECT_ROOT, process.env.STUDIO_NOTES_FILE || "studiorunner.md");
const RUNNER_DIR = join(PROJECT_ROOT, RUNNER_DIR_NAME);
const RAW_FILE = join(RUNNER_DIR, "raw.md");
const CHAT_FILE = join(RUNNER_DIR, "chat.md");
const SCREENSHOTS_DIR = join(RUNNER_DIR, "screenshots");
const AUDIO_DIR = join(RUNNER_DIR, "audio");

const WHISPER_MODEL =
  process.env.WHISPER_MODEL ||
  "/opt/homebrew/share/whisper-cpp/models/ggml-medium.en.bin";
const WHISPER_LANG = process.env.WHISPER_LANG || "en";

const MIC_GAIN_DB = parseInt(process.env.STUDIO_MIC_GAIN || "25", 10);
const MIC_PREROLL_SEC = parseFloat(process.env.STUDIO_MIC_PREROLL ?? "0.5");
const MIC_POSTROLL_SEC = parseFloat(process.env.STUDIO_MIC_POSTROLL ?? "0.5");
const MIC_ROLLING_PATH = "/tmp/studio-runner-mic-rolling.raw";

const DAW_DEVICE = process.env.STUDIO_DAW_DEVICE ?? "BlackHole 2ch";
const DAW_PREROLL_SEC = parseInt(process.env.STUDIO_DAW_PREROLL || "10", 10);
const DAW_ROLLING_PATH = "/tmp/studio-runner-daw-rolling.raw";

const DEEPSEEK_MODEL = process.env.STUDIO_DEEPSEEK_MODEL || "deepseek-chat";
const TTS_ENABLED = (process.env.STUDIO_TTS ?? "1") !== "0";
const TTS_VOICE = process.env.STUDIO_TTS_VOICE;
const PRUNE_ASSETS = process.env.STUDIO_PRUNE_ASSETS === "1";

const MIC_BYTES_PER_SEC = 16000 * 1 * 2;
const DAW_BYTES_PER_SEC = 44100 * 2 * 2;

// ── Helpers ──────────────────────────────────────────────────────────────

function ts(d: Date = new Date()): string {
  return `${String(d.getFullYear()).slice(2)}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}${String(d.getHours()).padStart(2, "0")}${String(d.getMinutes()).padStart(2, "0")}${String(d.getSeconds()).padStart(2, "0")}`;
}

function humanTs(d: Date = new Date()): string {
  const yy = String(d.getFullYear()).slice(2);
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const mi = String(d.getMinutes()).padStart(2, "0");
  const ss = String(d.getSeconds()).padStart(2, "0");
  return `${yy}-${mm}-${dd} ${hh}:${mi}:${ss}`;
}

function ensureDir(d: string): void {
  if (!existsSync(d)) mkdirSync(d, { recursive: true });
}

function ensureLayout(): void {
  ensureDir(RUNNER_DIR);
  ensureDir(SCREENSHOTS_DIR);
  ensureDir(AUDIO_DIR);
  if (!existsSync(NOTES_FILE)) {
    writeFileSync(
      NOTES_FILE,
      "# Studio Runner\n\n## TODO\n\n## Track notes\n\n## Open questions\n\n## Session timeline\n",
    );
  }
  if (!existsSync(RAW_FILE)) {
    writeFileSync(RAW_FILE, "<!-- consolidated_through: none -->\n\n");
  }
}

// ── Whisper / screenshot ─────────────────────────────────────────────────

async function transcribe(fp: string): Promise<string> {
  // --no-fallback disables whisper's temperature-fallback retry, the main
  // source of pattern hallucinations ("1, 2, 3" → "…6, 7, 8, 9, 10") on
  // heavily-quantised models.
  const r =
    await $`whisper-cli -m ${WHISPER_MODEL} -l ${WHISPER_LANG} --no-timestamps -t 6 --no-speech-thold 0.5 --no-fallback -f "${fp}" 2>/dev/null`.quiet();
  return r.stdout.toString().trim().replace(/^\[.*?\]\s*/, "");
}

async function takeScreenshot(fp: string): Promise<void> {
  await $`screencapture -x "${fp}"`.quiet();
}

// ── DAW rolling recorder ────────────────────────────────────────────────

let dawProc: ReturnType<typeof Bun.spawn> | null = null;
let dawAvailable = false;
let dawWarningLogged = false;

function spawnDawSox(): ReturnType<typeof Bun.spawn> {
  return Bun.spawn(
    [
      "sox",
      "-t", "coreaudio", DAW_DEVICE,
      "-r", "44100", "-c", "2", "-b", "16",
      "-e", "signed-integer", "-t", "raw",
      DAW_ROLLING_PATH,
    ],
    { stderr: "ignore" },
  );
}

function startDawRecorder(): void {
  if (!DAW_DEVICE) return;
  try { unlinkSync(DAW_ROLLING_PATH); } catch { /* ok */ }
  try {
    dawProc = spawnDawSox();
  } catch (err) {
    if (!dawWarningLogged) {
      console.error(`DAW capture unavailable (sox spawn failed: ${err}) — continuing mic-only`);
      dawWarningLogged = true;
    }
    dawProc = null;
    dawAvailable = false;
    return;
  }
  dawAvailable = true;
  setTimeout(() => {
    if (dawProc && dawProc.exitCode !== null) {
      if (!dawWarningLogged) {
        console.error(
          `DAW capture unavailable (device '${DAW_DEVICE}' not found) — continuing mic-only`,
        );
        dawWarningLogged = true;
      }
      dawProc = null;
      dawAvailable = false;
    }
  }, 1000);
}

function stopDawRecorder(): void {
  dawProc?.kill();
  dawProc = null;
  dawAvailable = false;
  try { unlinkSync(DAW_ROLLING_PATH); } catch { /* ok */ }
}

async function resetDawRecorder(): Promise<void> {
  if (!DAW_DEVICE) return;
  const wasAvailable = dawAvailable;
  if (dawProc) {
    dawProc.kill();
    try { await dawProc.exited; } catch { /* ok */ }
    dawProc = null;
  }
  try { unlinkSync(DAW_ROLLING_PATH); } catch { /* ok */ }
  if (wasAvailable) {
    try {
      dawProc = spawnDawSox();
      dawAvailable = true;
    } catch {
      dawAvailable = false;
    }
  }
}

async function extractDawClip(
  utteranceStartMs: number,
  utteranceEndMs: number,
  outPath: string,
): Promise<boolean> {
  if (!dawAvailable || !existsSync(DAW_ROLLING_PATH)) return false;
  let fileSize: number;
  try { fileSize = statSync(DAW_ROLLING_PATH).size; } catch { return false; }
  const fileDurationSec = fileSize / DAW_BYTES_PER_SEC;
  const effectiveStartMs = Date.now() - fileDurationSec * 1000;
  const windowStartMs = utteranceStartMs - DAW_PREROLL_SEC * 1000;
  const startOffsetSec = Math.max(0, (windowStartMs - effectiveStartMs) / 1000);
  const clippedStartMs = Math.max(windowStartMs, effectiveStartMs);
  const durationSec = (utteranceEndMs - clippedStartMs) / 1000;
  if (durationSec <= 0) return false;
  try {
    await $`sox -t raw -r 44100 -c 2 -b 16 -e signed-integer "${DAW_ROLLING_PATH}" "${outPath}" trim ${startOffsetSec} ${durationSec}`.quiet();
    return existsSync(outPath);
  } catch (err) {
    console.error("DAW clip extraction failed:", err);
    return false;
  }
}

// ── Mic rolling buffer ───────────────────────────────────────────────────

let micProc: ReturnType<typeof Bun.spawn> | null = null;
let micAvailable = false;

function spawnMicSox(): ReturnType<typeof Bun.spawn> {
  return Bun.spawn(
    [
      "sox", "-d",
      "-r", "16000", "-c", "1", "-b", "16",
      "-e", "signed-integer", "-t", "raw",
      MIC_ROLLING_PATH,
      "gain", String(MIC_GAIN_DB),
    ],
    { stderr: "ignore" },
  );
}

function startMicRecorder(): void {
  try { unlinkSync(MIC_ROLLING_PATH); } catch { /* ok */ }
  try {
    micProc = spawnMicSox();
  } catch (err) {
    console.error("Mic recorder spawn failed:", err);
    micProc = null;
    micAvailable = false;
    return;
  }
  micAvailable = true;
  setTimeout(() => {
    if (micProc && micProc.exitCode !== null) {
      console.error("Mic recorder died at startup — no input device?");
      micProc = null;
      micAvailable = false;
    }
  }, 1000);
}

function stopMicRecorder(): void {
  micProc?.kill();
  micProc = null;
  micAvailable = false;
  try { unlinkSync(MIC_ROLLING_PATH); } catch { /* ok */ }
}

async function extractMicClip(
  utteranceStartMs: number,
  utteranceEndMs: number,
  outPath: string,
): Promise<boolean> {
  if (!micAvailable || !existsSync(MIC_ROLLING_PATH)) return false;
  let fileSize: number;
  try { fileSize = statSync(MIC_ROLLING_PATH).size; } catch { return false; }
  // Derive the recording's wall-clock start from how much audio is actually
  // on disk, not from Date.now() at spawn. Self-corrects for sox's variable
  // CoreAudio cold-start AND OS write-buffer lag.
  const fileDurationSec = fileSize / MIC_BYTES_PER_SEC;
  const effectiveStartMs = Date.now() - fileDurationSec * 1000;
  const windowStartMs = utteranceStartMs - MIC_PREROLL_SEC * 1000;
  const windowEndMs = utteranceEndMs + MIC_POSTROLL_SEC * 1000;
  const startOffsetSec = Math.max(0, (windowStartMs - effectiveStartMs) / 1000);
  const clippedStartMs = Math.max(windowStartMs, effectiveStartMs);
  const durationSec = (windowEndMs - clippedStartMs) / 1000;
  if (durationSec <= 0) return false;
  try {
    await $`sox -t raw -r 16000 -c 1 -b 16 -e signed-integer "${MIC_ROLLING_PATH}" "${outPath}" trim ${startOffsetSec} ${durationSec}`.quiet();
    return existsSync(outPath);
  } catch (err) {
    console.error("Mic clip extraction failed:", err);
    return false;
  }
}

// ── MIDI bindings ────────────────────────────────────────────────────────

type MidiBinding =
  | { kind: "note"; channel: number; note: number; portName: string }
  | { kind: "cc"; channel: number; cc: number; portName: string };

let midiPorts: MidiInput[] = [];
let midiPortNames: string[] = [];
let memoBinding: MidiBinding | null = null;
let askBinding: MidiBinding | null = null;

function describeMidiBinding(b: MidiBinding): string {
  const label = b.kind === "note"
    ? `Note ${b.note} ch${b.channel + 1}`
    : `CC ${b.cc} ch${b.channel + 1}`;
  return `${b.portName} · ${label}`;
}

function bindingsEqual(a: MidiBinding, b: MidiBinding): boolean {
  if (a.kind !== b.kind || a.portName !== b.portName || a.channel !== b.channel) return false;
  if (a.kind === "note" && b.kind === "note") return a.note === b.note;
  if (a.kind === "cc" && b.kind === "cc") return a.cc === b.cc;
  return false;
}

function openAllMidiPorts(): void {
  const probe = new MidiInput();
  const portCount = probe.getPortCount();
  midiPortNames = [];
  for (let i = 0; i < portCount; i++) midiPortNames.push(probe.getPortName(i));
  if (portCount === 0) {
    throw new Error("No MIDI input devices found — connect a controller and retry");
  }
  midiPorts = [];
  for (let i = 0; i < portCount; i++) {
    const inp = new MidiInput();
    inp.openPort(i);
    midiPorts.push(inp);
  }
}

async function captureBinding(label: string, exclude: MidiBinding | null): Promise<MidiBinding> {
  console.error(`Press and hold the button/pedal you want to use to ${label}...`);
  const result = await new Promise<{ binding: MidiBinding; portIdx: number }>((resolve) => {
    let captured: { binding: MidiBinding; portIdx: number } | null = null;
    midiPorts.forEach((inp, idx) => {
      inp.on("message", (_dt: number, msg: number[]) => {
        const [status, data1, data2] = msg;
        const type = status & 0xf0;
        const channel = status & 0x0f;

        if (!captured) {
          let candidate: MidiBinding | null = null;
          if (type === 0x90 && data2 > 0) {
            candidate = { kind: "note", channel, note: data1, portName: midiPortNames[idx] };
          } else if (type === 0xb0 && data2 >= 64) {
            candidate = { kind: "cc", channel, cc: data1, portName: midiPortNames[idx] };
          }
          if (!candidate) return;
          if (exclude && bindingsEqual(candidate, exclude)) {
            console.error("That button is already bound to the other action — pick a different one.");
            return;
          }
          captured = { binding: candidate, portIdx: idx };
          return;
        }

        // Consume the matching "up" so the session doesn't start mid-press.
        if (idx !== captured.portIdx) return;
        const b = captured.binding;
        if (b.kind === "note" && channel === b.channel && data1 === b.note) {
          if (type === 0x80 || (type === 0x90 && data2 === 0)) resolve(captured);
        } else if (b.kind === "cc" && type === 0xb0 && channel === b.channel && data1 === b.cc) {
          if (data2 < 64) resolve(captured);
        }
      });
    });
  });
  midiPorts.forEach((p) => { try { p.removeAllListeners("message"); } catch { /* ok */ } });
  console.error(`Bound: ${describeMidiBinding(result.binding)}`);
  return result.binding;
}

async function learnTwoBindings(): Promise<void> {
  openAllMidiPorts();
  memoBinding = await captureBinding("leave a note", null);
  askBinding = await captureBinding("ask a question", memoBinding);
}

function shutdownMidi(): void {
  midiPorts.forEach((p) => {
    try { p.removeAllListeners("message"); } catch { /* ok */ }
    try { p.closePort(); } catch { /* ok */ }
  });
  midiPorts = [];
  memoBinding = null;
  askBinding = null;
}

// ── Press queues + gate ──────────────────────────────────────────────────

let listening = false;
let activeBinding: "memo" | "ask" | null = null;
let pressStartMs = 0;

interface MicCapture { startMs: number; endMs: number; }

const memoQueue: MicCapture[] = [];
const askQueue: MicCapture[] = [];
let memoSignal: (() => void) | null = null;
let askSignal: (() => void) | null = null;
let consolidationSignal: (() => void) | null = null;
let consolidationPending = false;

function nudgeMemo(): void { if (memoSignal) { memoSignal(); memoSignal = null; } }
function nudgeAsk(): void { if (askSignal) { askSignal(); askSignal = null; } }
function nudgeConsolidation(): void {
  consolidationPending = true;
  if (consolidationSignal) { consolidationSignal(); consolidationSignal = null; }
}

function attachMidiGate(): void {
  midiPorts.forEach((inp) => {
    inp.on("message", (_dt: number, msg: number[]) => {
      if (!listening) return;
      const [status, data1, data2] = msg;
      const type = status & 0xf0;
      const channel = status & 0x0f;

      const handle = (b: MidiBinding, which: "memo" | "ask") => {
        if (b.kind === "note") {
          if (channel !== b.channel || data1 !== b.note) return;
          if (type === 0x90 && data2 > 0) onPressDown(which);
          else if (type === 0x80 || (type === 0x90 && data2 === 0)) onPressUp(which);
        } else {
          if (type !== 0xb0 || channel !== b.channel || data1 !== b.cc) return;
          if (data2 >= 64) onPressDown(which);
          else onPressUp(which);
        }
      };

      if (memoBinding) handle(memoBinding, "memo");
      if (askBinding) handle(askBinding, "ask");
    });
  });
}

function onPressDown(which: "memo" | "ask"): void {
  if (activeBinding) return;
  activeBinding = which;
  pressStartMs = Date.now();
}

function onPressUp(which: "memo" | "ask"): void {
  if (activeBinding !== which) return;
  activeBinding = null;
  const cap = { startMs: pressStartMs, endMs: Date.now() };
  if (which === "memo") { memoQueue.push(cap); nudgeMemo(); }
  else { askQueue.push(cap); nudgeAsk(); }
}

// ── Raw entry append ─────────────────────────────────────────────────────

interface RawEntryInput {
  timestamp: string;
  micText: string;
  audioRel?: string;
  screenshotRel?: string;
  dawText?: string;
}

function appendRawEntry(e: RawEntryInput): void {
  const human = humanTs(new Date(
    2000 + parseInt(e.timestamp.slice(0, 2), 10),
    parseInt(e.timestamp.slice(2, 4), 10) - 1,
    parseInt(e.timestamp.slice(4, 6), 10),
    parseInt(e.timestamp.slice(6, 8), 10),
    parseInt(e.timestamp.slice(8, 10), 10),
    parseInt(e.timestamp.slice(10, 12), 10),
  ));
  const lines = [
    "",
    `## ${human}`,
    `ts: ${e.timestamp}`,
  ];
  if (e.audioRel) lines.push(`audio: ${e.audioRel}`);
  if (e.screenshotRel) lines.push(`screenshot: ${e.screenshotRel}`);
  lines.push(`Gianfranco: ${e.micText}`);
  if (e.dawText && e.dawText.length > 0) lines.push(`DAW: ${e.dawText}`);
  lines.push("---");
  lines.push("");
  appendFileSync(RAW_FILE, lines.join("\n"));
}

// ── Memo worker ──────────────────────────────────────────────────────────

async function memoWorker(): Promise<void> {
  let lastText = "";
  while (listening) {
    const cap = memoQueue.shift();
    if (!cap) {
      await new Promise<void>((r) => { memoSignal = r; });
      continue;
    }
    try {
      lastText = await processMemo(cap, lastText);
    } catch (err) {
      console.error("memo error:", err);
    }
  }
}

async function processMemo(cap: MicCapture, lastText: string): Promise<string> {
  // Let sox flush its write buffer before extracting.
  await new Promise((r) => setTimeout(r, 500));

  const tmpMic = `/tmp/studio-runner-memo-${cap.startMs}.wav`;
  const hasMic = await extractMicClip(cap.startMs, cap.endMs, tmpMic);
  if (!hasMic) return lastText;

  const text = await transcribe(tmpMic);
  try { unlinkSync(tmpMic); } catch { /* ok */ }

  if (text.length === 0 || text === lastText) {
    return text.length > 0 ? "" : lastText;
  }

  const timestamp = ts(new Date(cap.startMs));
  const screenshotRel = `${RUNNER_DIR_NAME}/screenshots/${timestamp}.png`;
  const audioRel = `${RUNNER_DIR_NAME}/audio/${timestamp}.wav`;
  const screenshotAbs = join(SCREENSHOTS_DIR, `${timestamp}.png`);
  const audioAbs = join(AUDIO_DIR, `${timestamp}.wav`);

  await takeScreenshot(screenshotAbs);
  const hasDaw = await extractDawClip(cap.startMs, cap.endMs, audioAbs);
  const dawText = hasDaw ? await transcribe(audioAbs) : "";

  appendRawEntry({
    timestamp,
    micText: text,
    audioRel: hasDaw ? audioRel : undefined,
    screenshotRel,
    dawText: dawText.length > 0 ? dawText : undefined,
  });
  await resetDawRecorder();

  console.error(`[${timestamp}] ${text}`);
  nudgeConsolidation();
  return text;
}

// ── Ask worker ───────────────────────────────────────────────────────────

async function askWorker(): Promise<void> {
  while (listening) {
    const cap = askQueue.shift();
    if (!cap) {
      await new Promise<void>((r) => { askSignal = r; });
      continue;
    }
    try {
      await processAsk(cap);
    } catch (err) {
      console.error("ask error:", err);
    }
  }
}

async function processAsk(cap: MicCapture): Promise<void> {
  await new Promise((r) => setTimeout(r, 500));
  const tmpMic = `/tmp/studio-runner-ask-${cap.startMs}.wav`;
  const hasMic = await extractMicClip(cap.startMs, cap.endMs, tmpMic);
  if (!hasMic) return;
  const question = await transcribe(tmpMic);
  try { unlinkSync(tmpMic); } catch { /* ok */ }
  if (question.length === 0) return;
  console.error(`Q: ${question}`);

  const state = existsSync(NOTES_FILE) ? readFileSync(NOTES_FILE, "utf-8") : "";
  const recent = readUnprocessedRaw();

  const system =
    "You are a concise music-production assistant. The producer is mid-session, listening through speakers, so answer briefly and practically — short sentences, no preamble. When referring to a specific past note, cite its time in HH:MM form. If the answer is not in the provided context, say so.";

  const user =
`=== Current track state ===
${state || "(empty)"}

=== Unconsolidated recent notes (latest activity, may overlap with state) ===
${recent || "(none)"}

The producer asks: ${question}`;

  let answer: string;
  try {
    answer = await deepseek(system, user);
  } catch (err) {
    console.error("DeepSeek call failed:", err);
    return;
  }

  console.error(`A: ${answer}\n`);
  appendChat(question, answer);
  if (TTS_ENABLED) speak(answer);
}

function appendChat(question: string, answer: string): void {
  const block = `\n## ${humanTs()}\n**Q:** ${question}\n\n**A:** ${answer}\n\n---\n`;
  appendFileSync(CHAT_FILE, block);
}

function speak(text: string): void {
  const args = TTS_VOICE ? ["-v", TTS_VOICE, text] : [text];
  try {
    Bun.spawn(["say", ...args], { stdout: "ignore", stderr: "ignore" });
  } catch (err) {
    console.error("`say` failed:", err);
  }
}

// ── Raw parsing ──────────────────────────────────────────────────────────

interface RawEntry {
  ts: string;
  human: string;
  body: string;
  audioRel?: string;
  screenshotRel?: string;
}

function parseRaw(content: string): { watermark: string; entries: RawEntry[] } {
  const lines = content.split("\n");
  let watermark = "none";
  let i = 0;
  if (lines[0] && lines[0].startsWith("<!-- consolidated_through:")) {
    const m = lines[0].match(/consolidated_through:\s*(\S+)\s*-->/);
    if (m) watermark = m[1];
    i = 1;
  }
  const entries: RawEntry[] = [];
  let buf: string[] = [];
  for (; i < lines.length; i++) {
    const ln = lines[i];
    if (ln === "---") {
      if (buf.length) {
        const block = buf.join("\n");
        const tsMatch = block.match(/^ts:\s*(\d+)/m);
        const humanMatch = block.match(/^##\s+(.+)$/m);
        const audioMatch = block.match(/^audio:\s*(.+)$/m);
        const screenshotMatch = block.match(/^screenshot:\s*(.+)$/m);
        if (tsMatch && humanMatch) {
          entries.push({
            ts: tsMatch[1],
            human: humanMatch[1],
            body: block,
            audioRel: audioMatch?.[1]?.trim(),
            screenshotRel: screenshotMatch?.[1]?.trim(),
          });
        }
      }
      buf = [];
    } else {
      buf.push(ln);
    }
  }
  return { watermark, entries };
}

function readUnprocessedRaw(): string {
  if (!existsSync(RAW_FILE)) return "";
  const content = readFileSync(RAW_FILE, "utf-8");
  const { watermark, entries } = parseRaw(content);
  const unprocessed = watermark === "none"
    ? entries
    : entries.filter((e) => e.ts > watermark);
  return unprocessed.map((e) => `${e.body}\n---`).join("\n\n");
}

// ── Consolidation worker ─────────────────────────────────────────────────

async function consolidationWorker(): Promise<void> {
  while (listening) {
    if (!consolidationPending) {
      await new Promise<void>((r) => { consolidationSignal = r; });
      continue;
    }
    consolidationPending = false;
    try {
      await runConsolidation();
    } catch (err) {
      console.error("consolidation failed:", err);
    }
  }
}

async function runConsolidation(): Promise<void> {
  if (!existsSync(RAW_FILE)) return;
  const content = readFileSync(RAW_FILE, "utf-8");
  const { watermark, entries } = parseRaw(content);
  const unprocessed = watermark === "none"
    ? entries
    : entries.filter((e) => e.ts > watermark);
  if (unprocessed.length === 0) return;

  const state = existsSync(NOTES_FILE) ? readFileSync(NOTES_FILE, "utf-8") : "";

  const system =
`You maintain a markdown document capturing the live state of a music-production session.
Always preserve these four sections in this exact order:

## TODO
Checkbox list of action items the producer has mentioned (e.g. "- [ ] tame vocal sibilance bar 32"). Tick items the producer has marked done.

## Track notes
General considerations and decisions about the track (BPM, key, arrangement, mix decisions, sound choices). Free-form prose or short bullets.

## Open questions
Things the producer wondered aloud but hasn't decided. Remove an item once it's been answered or resolved.

## Session timeline
Condensed chronological summary, one bullet per meaningful utterance, oldest first. Format each bullet as:
- HH:MM — short paraphrase ([audio](<audio path>) · [screenshot](<screenshot path>))
where the paths come verbatim from the entry's "audio:" and "screenshot:" fields.

Keep prior content unless the new utterances explicitly supersede it. Output ONLY the full updated markdown document — no preamble, no explanation, no code fence.`;

  const user =
`=== Current state ===
${state || "(empty — first consolidation)"}

=== New raw utterances ===
${unprocessed.map((e) => `${e.body}\n---`).join("\n\n")}

Output the updated document.`;

  let updated: string;
  try {
    updated = await deepseek(system, user);
  } catch (err) {
    console.error("consolidation DeepSeek call failed:", err);
    return;
  }

  // Atomic state write.
  const tmpState = NOTES_FILE + ".tmp";
  writeFileSync(tmpState, updated.endsWith("\n") ? updated : updated + "\n");
  renameSync(tmpState, NOTES_FILE);

  // Advance the watermark to the highest ts we just consolidated.
  const newWatermark = unprocessed[unprocessed.length - 1].ts;
  advanceWatermark(content, newWatermark);

  if (PRUNE_ASSETS) {
    for (const e of unprocessed) {
      if (e.audioRel) { try { unlinkSync(join(PROJECT_ROOT, e.audioRel)); } catch { /* ok */ } }
      if (e.screenshotRel) { try { unlinkSync(join(PROJECT_ROOT, e.screenshotRel)); } catch { /* ok */ } }
    }
  }

  console.error(`consolidated ${unprocessed.length} entr${unprocessed.length === 1 ? "y" : "ies"}`);
}

function advanceWatermark(currentContent: string, newWatermark: string): void {
  const lines = currentContent.split("\n");
  const header = `<!-- consolidated_through: ${newWatermark} -->`;
  if (lines[0] && lines[0].startsWith("<!-- consolidated_through:")) {
    lines[0] = header;
  } else {
    lines.unshift(header, "");
  }
  const tmp = RAW_FILE + ".tmp";
  writeFileSync(tmp, lines.join("\n"));
  renameSync(tmp, RAW_FILE);
}

// ── DeepSeek (Anthropic-compatible) ──────────────────────────────────────

async function deepseek(systemPrompt: string, userPrompt: string): Promise<string> {
  const key = process.env.STUDIORUNNER_AI_API_KEY;
  if (!key) throw new Error("STUDIORUNNER_AI_API_KEY not set");
  const r = await fetch("https://api.deepseek.com/anthropic/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: DEEPSEEK_MODEL,
      max_tokens: 4096,
      system: systemPrompt,
      messages: [{ role: "user", content: userPrompt }],
    }),
  });
  if (!r.ok) {
    const body = await r.text();
    throw new Error(`DeepSeek HTTP ${r.status}: ${body}`);
  }
  const j = await r.json() as { content?: Array<{ type: string; text?: string }> };
  return (j.content ?? []).map((b) => b.text ?? "").join("").trim();
}

// ── Lifecycle ────────────────────────────────────────────────────────────

function startListening(): void {
  if (listening) return;
  if (!memoBinding || !askBinding) {
    throw new Error("learnTwoBindings() must run first");
  }
  listening = true;
  startMicRecorder();
  startDawRecorder();
  attachMidiGate();
  void memoWorker();
  void askWorker();
  void consolidationWorker();
}

function stopListening(): void {
  if (!listening) return;
  listening = false;
  activeBinding = null;
  stopMicRecorder();
  midiPorts.forEach((p) => { try { p.removeAllListeners("message"); } catch { /* ok */ } });
  nudgeMemo();
  nudgeAsk();
  nudgeConsolidation();
  stopDawRecorder();
}

// ── Prune subcommand ─────────────────────────────────────────────────────

function prune(): void {
  if (!existsSync(RAW_FILE)) {
    console.error("Nothing to prune (raw stream does not exist).");
    return;
  }
  const content = readFileSync(RAW_FILE, "utf-8");
  const { watermark, entries } = parseRaw(content);
  if (watermark === "none") {
    console.error("Nothing has been consolidated yet — nothing to prune.");
    return;
  }
  const kept = entries.filter((e) => e.ts > watermark);
  const dropped = entries.length - kept.length;
  const header = `<!-- consolidated_through: ${watermark} -->`;
  const body = kept.map((e) => `${e.body}\n---`).join("\n\n");
  const out = body.length > 0 ? `${header}\n\n${body}\n` : `${header}\n\n`;
  const tmp = RAW_FILE + ".tmp";
  writeFileSync(tmp, out);
  renameSync(tmp, RAW_FILE);
  console.error(`pruned ${dropped} consolidated entr${dropped === 1 ? "y" : "ies"} from raw stream`);
}

// ── Bootstrap ────────────────────────────────────────────────────────────

if (import.meta.main) {
  if (process.argv[2] === "prune") {
    ensureLayout();
    prune();
    process.exit(0);
  }

  if (!process.env.STUDIORUNNER_AI_API_KEY) {
    console.error("STUDIORUNNER_AI_API_KEY is required — export it before starting studio-runner.");
    process.exit(1);
  }

  ensureLayout();
  console.error(
    `studio-runner  notes=${NOTES_FILE}  whisper=${WHISPER_MODEL.split("/").pop()}  deepseek=${DEEPSEEK_MODEL}`,
  );

  await learnTwoBindings();
  console.error("Listening — memo to log, ask to query. Ctrl+C to stop.");
  startListening();

  let shuttingDown = false;
  function shutdown(): void {
    if (shuttingDown) process.exit(1);
    shuttingDown = true;
    process.stderr.write("\nshutting down...\n");
    try { stopListening(); } catch { /* ok */ }
    try { shutdownMidi(); } catch { /* ok */ }
    setTimeout(() => process.exit(0), 200).unref();
  }
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}
