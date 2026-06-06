loadAPI(17);

host.defineController(
  "StudioRunner", "StudioRunner Transport", "1.0",
  "00000000-0000-0000-0000-000000000001"
);

// Input: Grid button presses. Output: StudioRunner virtual port (satisfies Bitwig, not actually used).
host.defineMidiPorts(1, 1);
host.addDeviceNameBasedDiscoveryPair(["Intech Studio: Grid"], ["StudioRunner"]);

var transport;
var isPlaying  = false;
var currentPos = 0;
var pausedAt   = 0;

function init() {
  transport = host.createTransport();
  transport.isPlaying().addValueObserver(function(playing) {
    isPlaying = playing;
  });
  transport.playPosition().addValueObserver(function(pos) {
    currentPos = pos;
  });
  host.getMidiInPort(0).setMidiCallback(onMidi);
}

// CC 44 = memo, CC 45 = ask (channel 0, Intech Studio: Grid)
function onMidi(status, data1, data2) {
  var isCC      = (status & 0xF0) === 0xB0;
  var isPressed  = data2 > 0;
  var isReleased = data2 === 0;

  if (!isCC || (data1 !== 44 && data1 !== 45)) return;

  if (isPressed && isPlaying) {
    pausedAt = currentPos;
    transport.playStartPosition().set(pausedAt);
    transport.stop();
  }

  // Memo resumes on release. Ask waits for StudioRunnerResume to call play().
  if (isReleased && data1 === 44) {
    transport.play();
  }
}

function flush() {}
function exit()  {}
