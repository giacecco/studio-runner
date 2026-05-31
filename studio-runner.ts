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
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";

// ── Configuration ────────────────────────────────────────────────────────

export const PROJECT_ROOT = process.env.STUDIO_PROJECT_ROOT || process.cwd();
export const MEMO_DIR = join(PROJECT_ROOT, "memos");
export const SCREENSHOTS_DIR = join(MEMO_DIR, "screenshots");
export const AUDIO_DIR = join(MEMO_DIR, "audio");
const SILENCE_GAP = 3; // seconds of silence to end an utterance
const MAX_UTTERANCE_CHUNKS = 30; // hard cap: kill recording after 30s of continuous speech
const MIC_GAIN_DB = parseInt(process.env.STUDIO_MIC_GAIN || "25", 10);
const SILENCE_THRESHOLD_DB = parseFloat(process.env.STUDIO_VAD_THRESHOLD || "-50");
export const WHISPER_MODEL =
  process.env.WHISPER_MODEL ||
  "/opt/homebrew/share/whisper-cpp/models/ggml-large-v3-turbo-q5_0.bin";
export const WHISPER_LANG = process.env.WHISPER_LANG || "en";

// DAW audio capture (CD quality, recorded from a virtual loopback device).
// Set STUDIO_DAW_DEVICE="" to disable DAW capture.
const DAW_DEVICE = process.env.STUDIO_DAW_DEVICE ?? "BlackHole 2ch";
const DAW_PREROLL_SEC = parseInt(process.env.STUDIO_DAW_PREROLL || "10", 10);
const DAW_ROLLING_PATH = "/tmp/studio-runner-daw-rolling.wav";

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
): void {
  const audioLine = dawAudioRelPath ? `\n[DAW audio](${dawAudioRelPath})\n` : "";
  const entry = `\n## ${timestamp}\n\n![screenshot](${screenshotRelPath})\n${audioLine}\n**Gianfranco:** ${text}\n\n---\n`;
  appendFileSync(memoFile(), entry);
}

// ── Audio / Whisper ──────────────────────────────────────────────────────


export async function transcribe(fp: string): Promise<string> {
  const r =
    await $`whisper-cli -m ${WHISPER_MODEL} -l ${WHISPER_LANG} --no-timestamps -t 6 --no-speech-thold 0.5 -f "${fp}" 2>/dev/null`.quiet();
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
let dawRecordingStartMs = 0;
let dawAvailable = false;
let dawWarningLogged = false;

function spawnDawSox(): ReturnType<typeof Bun.spawn> {
  return Bun.spawn(
    [
      "sox",
      "-t", "coreaudio", DAW_DEVICE,
      "-r", "44100", "-c", "2", "-b", "16",
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
  dawRecordingStartMs = Date.now();
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
      dawRecordingStartMs = Date.now();
      dawAvailable = true;
    } catch {
      dawAvailable = false;
    }
  }
}

export async function extractDawClip(
  utteranceStartMs: number,
  utteranceEndMs: number,
  outPath: string,
): Promise<boolean> {
  if (!dawAvailable || !existsSync(DAW_ROLLING_PATH)) return false;

  const windowStartMs = utteranceStartMs - DAW_PREROLL_SEC * 1000;
  const startOffsetSec = Math.max(0, (windowStartMs - dawRecordingStartMs) / 1000);
  const effectiveStartMs = Math.max(windowStartMs, dawRecordingStartMs);
  const durationSec = (utteranceEndMs - effectiveStartMs) / 1000;
  if (durationSec <= 0) return false;

  try {
    await $`sox "${DAW_ROLLING_PATH}" "${outPath}" trim ${startOffsetSec} ${durationSec}`.quiet();
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
}

// ── Listener loop ────────────────────────────────────────────────────────
//
// sox records continuously with its built-in silence detection — no chunks,
// no stitching, no gaps. Each call blocks until speech starts and then 3s of
// silence follow, yielding one clean utterance WAV per iteration.

let listening = false;
let currentSoxProc: ReturnType<typeof Bun.spawn> | null = null;

export function isListening(): boolean {
  return listening;
}

export function startListening(onEntry?: (entry: Entry) => void): void {
  if (listening) return;
  listening = true;
  startDawRecorder();
  listenerLoop(onEntry);
}

export function stopListening(): void {
  listening = false;
  currentSoxProc?.kill();
  stopDawRecorder();
}

async function listenerLoop(onEntry?: (entry: Entry) => void): Promise<void> {
  let lastText = "";

  while (listening) {
    const tmpPath = `/tmp/studio-runner-${Date.now()}.wav`;
    try {
      currentSoxProc = Bun.spawn([
        "sox", "-d", "-r", "16000", "-c", "1", "-b", "16", tmpPath,
        "gain", String(MIC_GAIN_DB),
        "silence", "1", "0.3", `${SILENCE_THRESHOLD_DB}d`,
        "1", `${String(SILENCE_GAP)}.0`, `${SILENCE_THRESHOLD_DB}d`,
      ], { stderr: "ignore" });

      // Hard cap: kill after MAX_UTTERANCE_CHUNKS seconds of continuous speech
      const cutoff = setTimeout(
        () => currentSoxProc?.kill(),
        MAX_UTTERANCE_CHUNKS * 1000,
      );
      await currentSoxProc.exited;
      clearTimeout(cutoff);
      currentSoxProc = null;
      const utteranceEndMs = Date.now();

      if (!listening) {
        try { unlinkSync(tmpPath); } catch { /* ok */ }
        break;
      }

      const text = await transcribe(tmpPath);

      if (text.length > 0 && text !== lastText) {
        lastText = text;
        const audioDurationSec = await getAudioDuration(tmpPath);
        const utteranceStartMs = utteranceEndMs - audioDurationSec * 1000;
        const timestamp = ts(new Date(utteranceStartMs));
        const screenshotRelPath = `screenshots/${timestamp}.png`;
        const dawAudioRelPath = `audio/${timestamp}.wav`;

        try { unlinkSync(tmpPath); } catch { /* ok */ }
        await takeScreenshot(join(MEMO_DIR, screenshotRelPath));
        const hasDaw = await extractDawClip(
          utteranceStartMs,
          utteranceEndMs,
          join(MEMO_DIR, dawAudioRelPath),
        );
        appendToMemo(
          timestamp,
          text,
          screenshotRelPath,
          hasDaw ? dawAudioRelPath : undefined,
        );
        await resetDawRecorder();

        const entry: Entry = {
          timestamp,
          text,
          screenshotRelPath,
          ...(hasDaw ? { dawAudioRelPath } : {}),
        };
        onEntry?.(entry);
        console.error(`[${timestamp}] ${text}`);
      } else {
        if (text.length > 0) lastText = ""; // duplicate: reset so same phrase can reappear
        try { unlinkSync(tmpPath); } catch { /* ok */ }
      }
    } catch (err) {
      console.error("Listener error:", err);
      currentSoxProc = null;
      try { unlinkSync(tmpPath); } catch { /* ok */ }
      await new Promise((r) => setTimeout(r, 500));
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
        startListening((entry) => {
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
  startListening((entry) => {
    pendingEntries.push(entry);
  });

  process.on("SIGINT", () => stopListening());
  process.on("SIGTERM", () => stopListening());

  console.error(
    `studio-runner MCP started  model=${WHISPER_MODEL.split("/").pop()}  memo=${mf}`,
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
}
