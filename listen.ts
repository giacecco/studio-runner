/**
 * studio-runner — standalone CLI
 *
 * Usage:
 *   bun run listen.ts
 *   STUDIO_PROJECT_ROOT=/path/to/project bun run listen.ts
 */

import {
  ensureMemo,
  learnMidiBinding,
  memoFile,
  shutdownMidi,
  startListening,
  stopListening,
  WHISPER_MODEL,
} from "./studio-runner.ts";

const mf = ensureMemo();

console.error(
  `studio-runner  model=${WHISPER_MODEL.split("/").pop()}  memo=${mf}`,
);

await learnMidiBinding();

console.error("Listening — hold your button to speak. Ctrl+C to stop.\n");

await startListening((entry) => {
  console.log(`[${entry.timestamp}] ${entry.text}`);
});

let shuttingDown = false;
function shutdown() {
  if (shuttingDown) {
    // Second Ctrl-C — bail out hard.
    process.exit(1);
  }
  shuttingDown = true;
  process.stderr.write("\nshutting down...\n");
  try { stopListening(); } catch { /* ok */ }
  try { shutdownMidi(); } catch { /* ok */ }
  // The MIDI native module and any in-flight sox kills can keep libuv
  // alive past stopListening(). Give cleanup a brief beat, then force-exit.
  setTimeout(() => process.exit(0), 200).unref();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
