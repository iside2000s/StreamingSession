import { XRDevice, metaQuest3 } from 'iwer';
import { createSession } from '@nvidia/cloudxr';

const seat = new URLSearchParams(location.search).get('seat') === 'b' ? 'b' : 'a';
document.querySelector('#seat').textContent = seat.toUpperCase();
const emulated = new XRDevice(metaQuest3);
emulated.installRuntime({forceInstall: true}); // This page is for desktop emulation only.
emulated.position.set(0, 1.6, 0);
const status = { seat, phase: 'ready', frames: 0, trackingSent: 0, renders: 0, error: '' };
status.codecs = RTCRtpReceiver.getCapabilities('video')?.codecs.map(value => value.mimeType);
status.diagnostics = [];
for (const level of ['warn', 'error']) {
  const original = console[level].bind(console);
  console[level] = (...values) => {
    original(...values);
    status.diagnostics.push(values.map(value => typeof value === 'string' ? value : String(value)).join(' '));
    status.diagnostics = status.diagnostics.slice(-6);
  };
}
let xrSession, stream, started = false;
function show() { document.querySelector('#status').textContent = JSON.stringify(status, null, 2); }
function fail(error) { status.failedAt = status.phase; status.phase = 'error'; status.error = String(error?.message ?? error); show(); }
setInterval(() => {
  show();
  fetch('/telemetry', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify(status)}).catch(() => {});
}, 1000);
document.querySelector('#start').onclick = async () => {
  if (started) return;
  started = true;
  try {
    const canvas = document.querySelector('canvas');
    const gl = canvas.getContext('webgl2', {alpha: false, antialias: false, xrCompatible: true});
    if (!gl) throw new Error('WebGL2 unavailable');
    status.phase = 'requesting-emulated-session';
    xrSession = await navigator.xr.requestSession('immersive-vr', {requiredFeatures: ['local-floor']});
    status.phase = 'creating-xr-layer';
    await gl.makeXRCompatible();
    const layer = new XRWebGLLayer(xrSession, gl);
    xrSession.updateRenderState({baseLayer: layer});
    const referenceSpace = await xrSession.requestReferenceSpace('local-floor');
    stream = createSession({
      serverAddress: '127.0.0.1', serverPort: seat === 'a' ? 50110 : 50210,
      useSecureConnection: false, gl, referenceSpace,
      perEyeWidth: 640, perEyeHeight: 512, deviceFrameRate: 60,
      maxStreamingBitrateKbps: 6000, codec: 'h264'
    }, {
      onStreamStarted: () => { status.phase = 'streaming'; show(); },
      onStreamStopped: error => { status.phase = 'stopped'; if (error) status.error = String(error.message ?? error); show(); },
      onMetrics: metrics => {
        if (Number.isFinite(metrics['streaming.frame_count'])) status.frames = metrics['streaming.frame_count'];
        if (Number.isFinite(metrics['streaming.framerate'])) status.fps = metrics['streaming.framerate'];
      }
    });
    stream.connect(); // CloudXR.js 6.4 returns void and reports async state via delegates.
    status.phase = 'connecting';
    function frame(time, xrFrame) {
      try {
        if (status.phase === 'connecting' || status.phase === 'streaming') {
          if (stream.sendTrackingStateToServer(time, xrFrame)) {
            status.trackingSent++;
            stream.render(time, xrFrame, layer);
            status.renders++;
          }
        }
      } catch (error) { fail(error); }
      xrSession.requestAnimationFrame(frame);
    }
    xrSession.requestAnimationFrame(frame);
    show();
  } catch (error) { fail(error); }
};
document.querySelector('#move').onclick = () => {
  emulated.position.x += 0.1;
  status.headX = emulated.position.x;
  show();
};
document.querySelector('#stop').onclick = async () => {
  stream?.disconnect();
  await xrSession?.end();
  status.phase = 'stopped';
  show();
};
show();
