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
var isPlaying       = false;
var wasPlaying      = false; // shared between Grid and done-signal handlers
var currentPos      = 0;
var pausedAt        = 0;
var awaitingAskDone = false;
var hasSignalPort   = false;

function init() {
  transport = host.createTransport();
  transport.isPlaying().addValueObserver(function(playing) { isPlaying = playing; });
  transport.playPosition().addValueObserver(function(pos)   { currentPos = pos;   });
  host.getMidiInPort(0).setMidiCallback(onMidiGrid);
  try {
    host.getMidiInPort(1).setMidiCallback(onMidiStudioRunner);
    hasSignalPort = true;
  } catch(e) {
    // StudioRunner not running yet — ask will fall back to resume on button release
  }
}

// Grid: CC 44 = memo, CC 45 = ask (channel 0)
function onMidiGrid(status, data1, data2) {
  var isCC      = (status & 0xF0) === 0xB0;
  var isPressed  = data2 > 0;
  var isReleased = data2 === 0;

  if (!isCC || (data1 !== 44 && data1 !== 45)) return;

  if (isPressed) {
    wasPlaying = isPlaying;
    if (isPlaying) {
      pausedAt = currentPos;
      transport.playStartPosition().set(pausedAt);
      transport.stop();
    }
    awaitingAskDone = (data1 === 45) && hasSignalPort;
  }

  if (isReleased) {
    if (!awaitingAskDone) {
      // Memo: resume on release (only if we actually paused it)
      if (wasPlaying) {
        transport.play();
        wasPlaying = false;
      }
    }
    // Ask: resume is handled by onMidiStudioRunner when done signal arrives
  }
}

// StudioRunner virtual source: CC 119 ch16 value 127 = ask flow done
function onMidiStudioRunner(status, data1, data2) {
  var isCC = (status & 0xF0) === 0xB0;
  var ch   = status & 0x0F;
  if (!isCC || ch !== 15 || data1 !== 119 || data2 !== 127) return;

  if (awaitingAskDone && wasPlaying) {
    host.scheduleTask(function() { transport.play(); }, null, 1000);
  }
  awaitingAskDone = false;
  wasPlaying = false;
}

function flush() {}
function exit()  {}
