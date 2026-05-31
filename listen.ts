/**
 * studio-runner — standalone CLI
 *
 * Usage:
 *   bun run listen.ts
 *   STUDIO_PROJECT_ROOT=/path/to/project bun run listen.ts
 */

import {
  ensureMemo,
  memoFile,
  startListening,
  stopListening,
  WHISPER_MODEL,
} from "./studio-runner.ts";

const mf = ensureMemo();

console.error(
  `studio-runner: listening  model=${WHISPER_MODEL.split("/").pop()}  memo=${mf}`,
);
console.error("(speak your comments while working — Ctrl+C to stop)\n");

startListening((entry) => {
  console.log(`[${entry.timestamp}] ${entry.text}`);
});

function shutdown() {
  process.stderr.write("\n");
  stopListening();
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
