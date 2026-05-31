/**
 * studio-runner — voice-to-memo listener for DAW production sessions
 *
 * When run directly, starts an MCP server for Claude Code:
 *   bun run studio-runner.ts
 *
 * When imported, exposes core functions used by listen.ts (standalone CLI).
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { $ } from "bun";
import { Input as MidiInput } from "@julusian/midi";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";

// ── Configuration ────────────────────────────────────────────────────────

export const PROJECT_ROOT = process.env.STUDIO_PROJECT_ROOT || process.cwd();
export const MEMO_DIR = join(PROJECT_ROOT, "memos");
export const SCREENSHOTS_DIR = join(MEMO_DIR, "screenshots");
export const AUDIO_DIR = join(MEMO_DIR, "audio");
const MIC_GAIN_DB = parseInt(process.env.STUDIO_MIC_GAIN || "25", 10);
export const WHISPER_MODEL =
  process.env.WHISPER_MODEL ||
  "/opt/homebrew/share/whisper-cpp/models/ggml-medium.en.bin";
export const WHISPER_LANG = process.env.WHISPER_LANG || "en";

// DAW audio capture (CD quality, recorded from a virtual loopback device).
// Set STUDIO_DAW_DEVICE="" to disable DAW capture.
const DAW_DEVICE = process.env.STUDIO_DAW_DEVICE ?? "BlackHole 2ch";
const DAW_PREROLL_SEC = parseInt(process.env.STUDIO_DAW_PREROLL || "10", 10);
const DAW_ROLLING_PATH = "/tmp/studio-runner-daw-rolling.raw";

// Mic rolling buffer — sox runs continuously so the audio device is always
// hot, avoiding the 200–700 ms cold-start latency that would otherwise eat
// the first words of every utterance.
const MIC_PREROLL_SEC = parseFloat(process.env.STUDIO_MIC_PREROLL ?? "0.5");
const MIC_POSTROLL_SEC = parseFloat(process.env.STUDIO_MIC_POSTROLL ?? "0.5");
const MIC_ROLLING_PATH = "/tmp/studio-runner-mic-rolling.raw";

// Both rolling buffers use raw PCM (no WAV header) so that extraction can
// read up to the actual on-disk byte count, not whatever stale length a
// still-being-written WAV header would advertise. Without this, the last
// few hundred ms of each utterance get clipped.

// ── Helpers ──────────────────────────────────────────────────────────────

export function ts(d: Date = new Date()): string {
  return `${String(d.getFullYear()).slice(2)}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}${String(d.getHours()).padStart(2, "0")}${String(d.getMinutes()).padStart(2, "0")}${String(d.getSeconds()).padStart(2, "0")}`;
}

export function dateStr(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

export function memoFile(): string {
  return join(MEMO_DIR, `${dateStr()}.md`);
}

export function ensureDir(dir: string): void {
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
}

export function ensureMemo(): string {
  ensureDir(MEMO_DIR);
  ensureDir(SCREENSHOTS_DIR);
  ensureDir(AUDIO_DIR);
  const mf = memoFile();
  if (!existsSync(mf)) {
    appendFileSync(mf, `# Session Memo — ${dateStr()}\n\n`);
  }
  return mf;
}

export function appendToMemo(
  timestamp: string,
  text: string,
  screenshotRelPath: string,
  dawAudioRelPath?: string,
  dawText?: string,
): void {
  // Heading uses just HH:MM:SS — the date is already in the file title
  // and filename, so repeating it on every entry is noise.
  const clock = `${timestamp.slice(6, 8)}:${timestamp.slice(8, 10)}:${timestamp.slice(10, 12)}`;
  const audioLine = dawAudioRelPath ? `[DAW audio](${dawAudioRelPath})\n` : "";
  const dawLine = dawText && dawText.length > 0 ? `**DAW:** ${dawText}\n` : "";
  const entry = `\n## ${clock}\n![screenshot](${screenshotRelPath})\n${audioLine}${dawLine}**Gianfranco:** ${text}\n---\n`;
  appendFileSync(memoFile(), entry);
}

// ── Audio / Whisper ──────────────────────────────────────────────────────


export async function transcribe(fp: string): Promise<string> {
  // --no-fallback disables whisper's temperature-fallback retry, which is the
  // main source of "1, 2, 3, 4, 5" → "…6, 7, 8, 9, 10" pattern hallucinations
  // under heavy quantisation. Default beam search (5/5) is kept for quality.
  const r =
    await $`whisper-cli -m ${WHISPER_MODEL} -l ${WHISPER_LANG} --no-timestamps -t 6 --no-speech-thold 0.5 --no-fallback -f "${fp}" 2>/dev/null`.quiet();
  return r.stdout.toString().trim().replace(/^\[.*?\]\s*/, "");
}

export async function takeScreenshot(fp: string): Promise<void> {
  await $`screencapture -x "${fp}"`.quiet();
}

export async function getAudioDuration(fp: string): Promise<number> {
  try {
    const r = await $`soxi -D "${fp}"`.quiet();
    return parseFloat(r.stdout.toString().trim()) || 0;
  } catch {
    return 0;
  }
}

// ── DAW capture ──────────────────────────────────────────────────────────
// A second sox process records DAW output from a virtual loopback device
// (BlackHole 2ch by default) at CD quality into a rolling temp file. After
// each utterance we extract the relevant time window and then reset the
// rolling file, so disk usage stays bounded to "time since last utterance".

let dawProc: ReturnType<typeof Bun.spawn> | null = null;
let dawAvailable = false;
let dawWarningLogged = false;
const DAW_BYTES_PER_SEC = 44100 * 2 * 2;

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

export function startDawRecorder(): void {
  if (!DAW_DEVICE) return;
  try {
    unlinkSync(DAW_ROLLING_PATH);
  } catch { /* ok */ }
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

  // Watchdog: if sox dies within 1s, the device probably isn't present.
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

export function stopDawRecorder(): void {
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

// ── Mic rolling buffer ───────────────────────────────────────────────────

let micRollingProc: ReturnType<typeof Bun.spawn> | null = null;
let micRollingAvailable = false;
const MIC_BYTES_PER_SEC = 16000 * 1 * 2;

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

export function startMicRecorder(): void {
  try { unlinkSync(MIC_ROLLING_PATH); } catch { /* ok */ }
  try {
    micRollingProc = spawnMicSox();
  } catch (err) {
    console.error("Mic recorder spawn failed:", err);
    micRollingProc = null;
    micRollingAvailable = false;
    return;
  }
  micRollingAvailable = true;
  setTimeout(() => {
    if (micRollingProc && micRollingProc.exitCode !== null) {
      console.error("Mic recorder died at startup — no input device?");
      micRollingProc = null;
      micRollingAvailable = false;
    }
  }, 1000);
}

export function stopMicRecorder(): void {
  micRollingProc?.kill();
  micRollingProc = null;
  micRollingAvailable = false;
  try { unlinkSync(MIC_ROLLING_PATH); } catch { /* ok */ }
}

export async function extractMicClip(
  utteranceStartMs: number,
  utteranceEndMs: number,
  outPath: string,
): Promise<boolean> {
  if (!micRollingAvailable || !existsSync(MIC_ROLLING_PATH)) return false;
  let fileSize: number;
  try { fileSize = statSync(MIC_ROLLING_PATH).size; } catch { return false; }
  // Derive the recording's wall-clock start from how much audio is actually
  // on disk, not from Date.now() at spawn time. This self-corrects for sox's
  // 200–700 ms CoreAudio cold-start AND any OS write-buffer lag, both of
  // which would otherwise push the trim offset past the real start of speech.
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

// ── DAW clip extraction ──────────────────────────────────────────────────

export async function extractDawClip(
  utteranceStartMs: number,
  utteranceEndMs: number,
  outPath: string,
): Promise<boolean> {
  if (!dawAvailable || !existsSync(DAW_ROLLING_PATH)) return false;

  let fileSize: number;
  try { fileSize = statSync(DAW_ROLLING_PATH).size; } catch { return false; }
  const fileDurationSec = fileSize / DAW_BYTES_PER_SEC;
  const effectiveRecordingStartMs = Date.now() - fileDurationSec * 1000;
  const windowStartMs = utteranceStartMs - DAW_PREROLL_SEC * 1000;
  const startOffsetSec = Math.max(0, (windowStartMs - effectiveRecordingStartMs) / 1000);
  const clippedStartMs = Math.max(windowStartMs, effectiveRecordingStartMs);
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

// ── Entry ────────────────────────────────────────────────────────────────

export interface Entry {
  timestamp: string;
  text: string;
  screenshotRelPath: string;
  dawAudioRelPath?: string;
  dawText?: string;
}

// ── MIDI push-to-talk ────────────────────────────────────────────────────
//
// Recording is gated by a MIDI message the user picks at startup: hold the
// button/pedal → mic records; release → recording ends and is queued for
// transcription. The bound message is learned interactively the first time
// the user hits any button.

export type MidiBinding =
  | { kind: "note"; channel: number; note: number; portName: string }
  | { kind: "cc"; channel: number; cc: number; portName: string };

let midiBinding: MidiBinding | null = null;
let midiInput: MidiInput | null = null;

export function describeMidiBinding(b: MidiBinding): string {
  const label = b.kind === "note"
    ? `Note ${b.note} ch${b.channel + 1}`
    : `CC ${b.cc} ch${b.channel + 1}`;
  return `${b.portName} · ${label}`;
}

export async function learnMidiBinding(): Promise<MidiBinding> {
  // Open every input port — CoreMIDI broadcasts, so the user can press any
  // button on any device and we'll hear it without disturbing whatever's
  // already consuming MIDI (the DAW).
  const probe = new MidiInput();
  const portCount = probe.getPortCount();
  const portNames: string[] = [];
  for (let i = 0; i < portCount; i++) portNames.push(probe.getPortName(i));
  if (portCount === 0) {
    throw new Error("No MIDI input devices found — connect a controller and retry");
  }

  const inputs: MidiInput[] = [];
  for (let i = 0; i < portCount; i++) inputs.push(new MidiInput());

  console.error("Press and hold the button/pedal you want to use for push-to-talk...");

  const result = await new Promise<{ binding: MidiBinding; idx: number }>(
    (resolve) => {
      let captured: { binding: MidiBinding; idx: number } | null = null;
      inputs.forEach((inp, idx) => {
        inp.on("message", (_dt: number, msg: number[]) => {
          const [status, data1, data2] = msg;
          const type = status & 0xf0;
          const channel = status & 0x0f;

          if (!captured) {
            if (type === 0x90 && data2 > 0) {
              captured = {
                binding: { kind: "note", channel, note: data1, portName: portNames[idx] },
                idx,
              };
            } else if (type === 0xb0 && data2 >= 64) {
              captured = {
                binding: { kind: "cc", channel, cc: data1, portName: portNames[idx] },
                idx,
              };
            }
            return;
          }

          // Consume the matching "up" so we don't start the session already
          // holding the button (which would trigger a phantom recording).
          if (idx !== captured.idx) return;
          const b = captured.binding;
          if (b.kind === "note" && channel === b.channel && data1 === b.note) {
            const isOff =
              type === 0x80 || (type === 0x90 && data2 === 0);
            if (isOff) resolve(captured);
          } else if (b.kind === "cc" && type === 0xb0 && channel === b.channel && data1 === b.cc) {
            if (data2 < 64) resolve(captured);
          }
        });
        inp.openPort(idx);
      });
    },
  );

  // Keep only the chosen port; drop listeners on the others.
  inputs.forEach((inp, idx) => {
    if (idx !== result.idx) {
      try { inp.closePort(); } catch { /* ok */ }
    }
  });
  midiInput = inputs[result.idx];
  midiInput.removeAllListeners("message");
  midiBinding = result.binding;
  console.error(`Bound to ${describeMidiBinding(result.binding)}`);
  return result.binding;
}

// ── Listener loop ────────────────────────────────────────────────────────

let listening = false;
let pressActive = false;
let pressStartMs = 0;

interface MicCapture {
  startMs: number;
  endMs: number;
}

const captureQueue: MicCapture[] = [];
let captureSignal: (() => void) | null = null;

function nudgeWorker(): void {
  if (captureSignal) { captureSignal(); captureSignal = null; }
}

export function isListening(): boolean {
  return listening;
}

export async function startListening(onEntry?: (entry: Entry) => void): Promise<void> {
  if (listening) return;
  if (!midiBinding || !midiInput) {
    throw new Error("Call learnMidiBinding() before startListening()");
  }
  listening = true;
  startMicRecorder();
  startDawRecorder();
  attachMidiGate();
  workerLoop(onEntry);
}

export function stopListening(): void {
  if (!listening) return;
  listening = false;
  pressActive = false;
  stopMicRecorder();
  // Detach the gate but keep the port open so a later startListening()
  // can re-arm without re-learning the binding.
  if (midiInput) {
    try { midiInput.removeAllListeners("message"); } catch { /* ok */ }
  }
  nudgeWorker();
  stopDawRecorder();
}

export function shutdownMidi(): void {
  if (midiInput) {
    try { midiInput.removeAllListeners("message"); } catch { /* ok */ }
    try { midiInput.closePort(); } catch { /* ok */ }
    midiInput = null;
  }
  midiBinding = null;
}

function attachMidiGate(): void {
  const input = midiInput!;
  const b = midiBinding!;
  input.on("message", (_dt: number, msg: number[]) => {
    if (!listening) return;
    const [status, data1, data2] = msg;
    const type = status & 0xf0;
    const channel = status & 0x0f;
    if (b.kind === "note") {
      if (channel !== b.channel || data1 !== b.note) return;
      if (type === 0x90 && data2 > 0) onPressDown();
      else if (type === 0x80 || (type === 0x90 && data2 === 0)) onPressUp();
    } else {
      if (type !== 0xb0 || channel !== b.channel || data1 !== b.cc) return;
      if (data2 >= 64) onPressDown();
      else onPressUp();
    }
  });
}

function onPressDown(): void {
  if (pressActive) return; // ignore repeats while already held
  pressActive = true;
  pressStartMs = Date.now();
}

function onPressUp(): void {
  if (!pressActive) return;
  pressActive = false;
  captureQueue.push({ startMs: pressStartMs, endMs: Date.now() });
  nudgeWorker();
}

async function processUtterance(
  cap: MicCapture,
  lastText: string,
  onEntry?: (entry: Entry) => void,
): Promise<string> {
  // Give sox time to flush its write buffer (~250 ms internal). Without
  // this wait, the last few hundred ms of speech are still buffered, AND
  // our file-size-derived offset math slides the whole window left by the
  // flush lag — so the tail is missing and the head is over-padded.
  await new Promise((r) => setTimeout(r, 500));
  const tmpMic = `/tmp/studio-runner-${cap.startMs}.wav`;
  const hasMic = await extractMicClip(cap.startMs, cap.endMs, tmpMic);
  if (!hasMic) return lastText;

  const text = await transcribe(tmpMic);
  try { unlinkSync(tmpMic); } catch { /* ok */ }

  if (text.length === 0 || text === lastText) {
    // duplicate: reset guard so same phrase can reappear after a pause
    return text.length > 0 ? "" : lastText;
  }

  const timestamp = ts(new Date(cap.startMs));
  const screenshotRelPath = `screenshots/${timestamp}.png`;
  const dawAudioRelPath = `audio/${timestamp}.wav`;

  await takeScreenshot(join(MEMO_DIR, screenshotRelPath));
  const hasDaw = await extractDawClip(
    cap.startMs,
    cap.endMs,
    join(MEMO_DIR, dawAudioRelPath),
  );
  const dawText = hasDaw ? await transcribe(join(MEMO_DIR, dawAudioRelPath)) : "";
  appendToMemo(
    timestamp,
    text,
    screenshotRelPath,
    hasDaw ? dawAudioRelPath : undefined,
    dawText.length > 0 ? dawText : undefined,
  );
  await resetDawRecorder();

  const entry: Entry = {
    timestamp,
    text,
    screenshotRelPath,
    ...(hasDaw ? { dawAudioRelPath } : {}),
    ...(dawText.length > 0 ? { dawText } : {}),
  };
  onEntry?.(entry);
  return text;
}

async function workerLoop(onEntry?: (entry: Entry) => void): Promise<void> {
  let lastText = "";
  while (listening) {
    const cap = captureQueue.shift();
    if (!cap) {
      await new Promise<void>((r) => { captureSignal = r; });
      continue;
    }
    try {
      lastText = await processUtterance(cap, lastText, onEntry);
    } catch (err) {
      console.error("Processing error:", err);
    }
  }
}

// ── MCP Server ───────────────────────────────────────────────────────────
// Only runs when the file is executed directly (not imported).

if (import.meta.main) {
  const pendingEntries: Entry[] = [];

  const server = new Server(
    { name: "studio-runner", version: "1.0.0" },
    { capabilities: { tools: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: [
      {
        name: "check_speech",
        description:
          "Return any new speech-to-text entries captured since the last call.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "start_listening",
        description: "Resume the background microphone listener.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "stop_listening",
        description: "Pause the background listener.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "get_status",
        description: "Return listener status and pending entry count.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "get_memo",
        description: "Read back the current session memo.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "take_screenshot",
        description: "Manually capture a full-screen screenshot now.",
        inputSchema: { type: "object", properties: {} },
      },
    ],
  }));

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    switch (request.params.name) {
      case "check_speech": {
        const drained = pendingEntries.splice(0, pendingEntries.length);
        return {
          content: [{ type: "text", text: JSON.stringify({ entries: drained }) }],
        };
      }

      case "start_listening": {
        ensureMemo();
        await startListening((entry) => {
          pendingEntries.push(entry);
        });
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({ status: "listening", memo: memoFile() }),
            },
          ],
        };
      }

      case "stop_listening": {
        stopListening();
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                status: "stopped",
                pending: pendingEntries.length,
              }),
            },
          ],
        };
      }

      case "get_status": {
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({
                listening: isListening(),
                pending: pendingEntries.length,
                memo: memoFile(),
                model: WHISPER_MODEL.split("/").pop(),
                projectRoot: MEMO_DIR.replace(/\/memos$/, ""),
              }),
            },
          ],
        };
      }

      case "get_memo": {
        const mf = memoFile();
        if (existsSync(mf)) {
          const content = readFileSync(mf, "utf-8");
          return { content: [{ type: "text", text: content }] };
        }
        return { content: [{ type: "text", text: "(no memo yet)" }] };
      }

      case "take_screenshot": {
        const timestamp = ts();
        const relPath = `screenshots/${timestamp}.png`;
        const absPath = join(MEMO_DIR, relPath);
        ensureMemo();
        await takeScreenshot(absPath);
        return {
          content: [
            {
              type: "text",
              text: JSON.stringify({ screenshot: relPath, timestamp }),
            },
          ],
        };
      }

      default:
        throw new Error(`Unknown tool: ${request.params.name}`);
    }
  });

  // Bootstrap
  const mf = ensureMemo();
  await learnMidiBinding();
  await startListening((entry) => {
    pendingEntries.push(entry);
  });

  process.on("SIGINT", () => { stopListening(); shutdownMidi(); });
  process.on("SIGTERM", () => { stopListening(); shutdownMidi(); });

  console.error(
    `studio-runner MCP started  model=${WHISPER_MODEL.split("/").pop()}  memo=${mf}`,
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}
