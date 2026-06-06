loadAPI(17);

host.defineController(
  "StudioRunner", "StudioRunner Resume", "1.0",
  "00000000-0000-0000-0000-000000000002"
);

// Input: StudioRunner virtual source (done signal). Output: StudioRunner virtual port (satisfies Bitwig).
host.defineMidiPorts(1, 1);
host.addDeviceNameBasedDiscoveryPair(["StudioRunner"], ["IAC Driver Bus 1"]);

var transport;

function init() {
  transport = host.createTransport();
  host.getMidiInPort(0).setMidiCallback(onMidi);
}

// CC 119 ch16 value 127 = StudioRunner ask flow finished
function onMidi(status, data1, data2) {
  var isCC = (status & 0xF0) === 0xB0;
  var ch   = status & 0x0F;
  if (isCC && ch === 15 && data1 === 119 && data2 === 127) {
    transport.play();
  }
}

function flush() {}
function exit()  {}
