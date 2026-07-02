loadAPI(17);

host.defineController(
  "StudioRunner", "StudioRunner Transport", "1.0",
  "00000000-0000-0000-0000-000000000001"
);

// Port 0 in:  Intech Studio: Grid  — button press/release events
// Port 1 in:  StudioRunner         — done signal from StudioRunner when ask flow finishes
// Port 0 out: IAC Driver Bus 1     — dummy, required by Bitwig to enable the script
host.defineMidiPorts(2, 1);
host.addDeviceNameBasedDiscoveryPair(["Intech Studio: Grid", "StudioRunner"], ["IAC Driver Bus 1"]);

var transport;
var masterTrack;
var cursorTrack;
var isPlaying       = false;
var wasPlaying      = false; // shared between Grid and done-signal handlers
var isMuted         = false;
var wasMuted        = false; // shared between Grid and done-signal handlers
var isArmed         = false; // true while StudioRunner session button is held
var currentPos      = 0;
var pausedAt        = 0;
var awaitingAskDone = false;
var suspended       = false; // transport/mute latched by an in-flight press cycle
var hasSignalPort   = false;
var pendingMinutes  = 0;
var pendingSeconds  = 0;
var currentBpm      = 120;

function init() {
  transport = host.createTransport();
  transport.isPlaying().addValueObserver(function(playing) { isPlaying = playing; });
  transport.playPosition().addValueObserver(function(pos)   { currentPos = pos;   });
  transport.tempo().addRawValueObserver(function(bpm)       { currentBpm = bpm;   });
  masterTrack = host.createMasterTrack(0);
  masterTrack.mute().addValueObserver(function(muted) { isMuted = muted; });
  cursorTrack = host.createCursorTrack(0, 0);
  cursorTrack.name().addValueObserver(function(name) { sendTrackName(name); });
  host.getMidiInPort(0).setMidiCallback(onMidiGrid);
  try {
    host.getMidiInPort(1).setMidiCallback(onMidiStudioRunner);
    hasSignalPort = true;
  } catch(e) {
    // StudioRunner not running yet — ask will fall back to resume on button release
  }
}

// SysEx F0 7D 01 <ASCII name bytes> F7 — track name notification to StudioRunner.
function sendTrackName(name) {
  var hex = "F07D01";
  for (var i = 0; i < name.length && i < 50; i++) {
    var code = name.charCodeAt(i);
    if (code < 0x20 || code > 0x7E) continue; // skip non-ASCII rather than mangle it
    hex += (code < 16 ? "0" : "") + code.toString(16).toUpperCase();
  }
  hex += "F7";
  host.getMidiOutPort(0).sendSysex(hex);
}

// Grid: CC 44 = memo, CC 45 = ask (channel 0)
function onMidiGrid(status, data1, data2) {
  var isCC      = (status & 0xF0) === 0xB0;
  var isPressed  = data2 > 0;
  var isReleased = data2 === 0;

  if (!isCC || (data1 !== 44 && data1 !== 45)) return;
  if (!isArmed) return;

  if (isPressed) {
    // Only latch on the first press of a cycle: a press that interrupts an
    // in-flight ask (or a controller repeating CC values while held) must
    // not overwrite wasPlaying/wasMuted with the already-stopped/muted
    // state — that would leave the master permanently muted.
    if (!suspended) {
      wasPlaying = isPlaying;
      if (isPlaying) {
        pausedAt = currentPos;
        transport.playStartPosition().set(pausedAt);
        transport.stop();
      }
      wasMuted = isMuted;
      if (!wasMuted) masterTrack.mute().set(true);
      suspended = true;
    }
    // The newest press owns the resume path; a stale ask-done signal is
    // ignored by onMidiStudioRunner once this flips to false.
    awaitingAskDone = (data1 === 45) && hasSignalPort;
  }

  if (isReleased) {
    if (!awaitingAskDone) {
      // Memo: resume transport and un-mute on release
      if (wasPlaying) {
        transport.play();
        wasPlaying = false;
      }
      if (!wasMuted) masterTrack.mute().set(false);
      wasMuted = false;
      suspended = false;
    }
    // Ask: resume and un-mute are handled by onMidiStudioRunner when done signal arrives
  }
}

// StudioRunner virtual source signals (all ch16):
//   CC 117 value=127 → session armed, value=0 → session disarmed
//   CC 116 value=minutes, CC 115 value=seconds, CC 114 value=127 → jump transport
//   CC 119 value=127                                              → ask flow done
function onMidiStudioRunner(status, data1, data2) {
  var isCC = (status & 0xF0) === 0xB0;
  var ch   = status & 0x0F;
  if (!isCC || ch !== 15) return;

  // Session armed/disarmed
  if (data1 === 117) { isArmed = (data2 === 127); return; }

  // GOTO: latch minutes/seconds then execute jump on trigger
  if (data1 === 116) { pendingMinutes = data2; return; }
  if (data1 === 115) { pendingSeconds = data2; return; }
  if (data1 === 114 && data2 === 127) {
    var totalSeconds = pendingMinutes * 60 + pendingSeconds;
    if (isPlaying) { transport.stop(); }
    try {
      // Seconds-based setters follow tempo automation exactly. Both are
      // needed: playPosition moves the visible playhead immediately,
      // playStartPosition marks where the next play begins.
      transport.playPositionInSeconds().set(totalSeconds);
      transport.playStartPositionInSeconds().set(totalSeconds);
    } catch (e) {
      // Fallback assumes constant tempo — off target when the project has
      // tempo automation before the requested position.
      var beats = totalSeconds * currentBpm / 60.0;
      transport.playPosition().set(beats);
      transport.playStartPosition().set(beats);
    }
    return;
  }

  // Ask flow done. A stale done signal (the ask was interrupted by a newer
  // press that now owns the resume) must not touch the latched state.
  if (data1 !== 119 || data2 !== 127) return;
  if (!awaitingAskDone) return;
  awaitingAskDone = false;
  suspended = false;
  if (wasPlaying) {
    host.scheduleTask(function() { transport.play(); }, null, 1000);
  }
  if (!wasMuted) masterTrack.mute().set(false);
  wasPlaying = false;
  wasMuted = false;
}

function flush() {}
function exit()  {}
