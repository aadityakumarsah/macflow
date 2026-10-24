'use strict';
const $ = id => document.getElementById(id);
// The fragment carries the session token, and — when this page is served
// from the web rather than by the app itself — the loopback port to send the
// recording to. Fragments are never sent to a server, so neither value leaves
// this machine.
const fragment = location.hash.slice(1);
const token = fragment.split('&')[0];
const bridgePort = new URLSearchParams(fragment.slice(fragment.indexOf('&') + 1)).get('port');
// Media always goes to the app on this machine. Same origin when the app
// serves this page; the loopback bridge when a web host does.
const api = bridgePort && /^\d+$/.test(bridgePort) ? `http://127.0.0.1:${bridgePort}` : '';
history.replaceState(null, '', location.pathname);
let display, camera, microphone, audioContext, screenRecorder, cameraRecorder;
let state = 'setup', screenChunks = [], cameraChunks = [], uploads = Promise.resolve(), uploadError;
let started = 0, pausedAt = 0, pausedDuration = 0, timer, heartbeat, totalBytes = 0, cameraDrag, captureID;
let screenBlob, cameraBlob, cameraPresentation, sourceName = 'Chrome tab';
const status = text => { $('status').textContent = text; };
function release(stream) { stream?.getTracks().forEach(track => track.stop()); }
function devices() {
  return navigator.mediaDevices.enumerateDevices().then(list => {
    for (const [id, kind] of [['cameras','videoinput'],['microphones','audioinput']]) {
      const select = $(id), previous = select.value;
      select.replaceChildren(new Option(kind === 'videoinput' ? 'Default camera' : 'Default microphone', ''));
      list.filter(device => device.kind === kind).forEach((device, i) => select.add(new Option(device.label || `${kind === 'videoinput' ? 'Camera' : 'Microphone'} ${i + 1}`, device.deviceId)));
      select.value = previous;
    }
  }).catch(() => {});
}
function mp4Type(withAudio) {
  const types = withAudio ? ['video/mp4;codecs=avc1.42001E,mp4a.40.2','video/mp4'] : ['video/mp4;codecs=avc1.42001E','video/mp4'];
  const type = types.find(value => MediaRecorder.isTypeSupported(value));
  if (!type) throw new Error('This browser cannot record MP4. Update Chrome, or use Window capture in FocusFlow.');
  return type;
}
async function choose() {
  if (state !== 'setup') return;
  $('choose').disabled = $('change').disabled = true;
  try {
    if (!token) throw new Error('Open Tab studio from the FocusFlow app to connect this recording.');
    mp4Type(true);
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: {displaySurface:'browser',frameRate:{ideal:60,max:60}}, audio:$('audio').checked, selfBrowserSurface:'exclude',surfaceSwitching:'exclude',monitorTypeSurfaces:'exclude',systemAudio:'exclude' });
    const track = stream.getVideoTracks()[0], settings = track.getSettings();
    if (settings.displaySurface !== 'browser') {
      release(stream);
      throw new Error('Select a tab in the “Chrome Tab” section. Window and screen sharing are not recorded in tab mode.');
    }
    release(display); display = stream;
    $('screen').srcObject = display; $('screen').style.display = 'block'; $('empty').hidden = true;
    await $('screen').play();
    sourceName = 'Selected Chrome tab'; $('source').textContent = sourceName;
    $('resolution').textContent = `${settings.width || 'Auto'} × ${settings.height || 'Auto'} · Live preview`;
    $('record').disabled = false;
    status(display.getAudioTracks().length ? 'Tab selected. Audio is included. Ready when you are.' : 'Tab selected. No tab audio was shared. Change source to include it.');
    track.addEventListener('ended', () => {
      if (state === 'recording' || state === 'paused') stop();
      else if (state === 'setup' && display === stream) { $('record').disabled = true; status('Sharing ended. Choose a tab to continue.'); }
    });
  } catch (error) { status(error.name === 'NotAllowedError' ? 'Selection cancelled. Choose a tab when you’re ready.' : error.message); }
  finally { $('choose').disabled = false; $('change').disabled = !display; }
}
async function configureCamera() {
  if (state !== 'setup') return;
  release(camera); camera = null; $('camera').hidden = true; $('record').disabled = true;
  if (!$('cam').checked) { $('record').disabled = !display?.active; return; }
  try {
    camera = await navigator.mediaDevices.getUserMedia({video:{deviceId:$('cameras').value ? {exact:$('cameras').value} : undefined,width:{ideal:1280},height:{ideal:720}},audio:false});
    $('camera').srcObject = camera; $('camera').hidden = false; await $('camera').play(); await devices();
  } catch (error) { $('cam').checked = false; status(`Camera unavailable: ${error.message}`); } finally { $('record').disabled = !display?.active; }
}
function setControls(locked) {
  ['audio','mic','cam','cameras','microphones'].forEach(id => $(id).disabled = locked);
  $('change').disabled = locked;
}
async function post(path, body) {
  let response;
  try {
    response = await fetch(api + path,{method:'POST',headers:{'X-FocusFlow-Token':token,'X-FocusFlow-Capture':captureID},body});
  } catch (error) {
    // Cross-origin to loopback fails this way when the app has quit.
    throw new Error(api ? 'FocusFlow is no longer listening. Keep the app open while recording.' : error.message);
  }
  if (!response.ok) throw new Error(await response.text() || 'Could not save to FocusFlow.');
}
function recorder(stream, chunks, path) {
  const result = new MediaRecorder(stream,{mimeType:mp4Type(stream.getAudioTracks().length > 0),videoBitsPerSecond:10000000});
  result.addEventListener('dataavailable', event => {
    if (!event.data.size) return;
    chunks.push(event.data); totalBytes += event.data.size;
    uploads = uploads.then(async () => { if (!uploadError) { try { await post(path,event.data); } catch(error) { uploadError = error; } } });
    // Keep a downloadable recovery copy without allowing unbounded browser memory growth.
    if (totalBytes > 512 * 1024 * 1024 && (state === 'recording' || state === 'paused')) { status('The 512 MB session limit was reached. Saving this recording…'); stop(); }
  });
  result.addEventListener('error', event => { status(`Recording error: ${event.error?.message || 'Encoder stopped'}`); stop(); });
  return result;
}
async function start() {
  if (state !== 'setup' || !display?.active) return;
  if (display.getVideoTracks()[0]?.getSettings().displaySurface !== 'browser') {
    release(display); display = null; $('record').disabled = true;
    status('Choose a Chrome tab before recording.'); return;
  }
  state = 'starting'; setControls(true); $('record').disabled = true;
  try {
    microphone = $('mic').checked ? await navigator.mediaDevices.getUserMedia({audio:{deviceId:$('microphones').value ? {exact:$('microphones').value}:undefined,echoCancellation:true,noiseSuppression:true},video:false}) : null;
    const tracks = [...display.getVideoTracks()];
    const sources = [$('audio').checked ? display : null, microphone].filter(stream => stream?.getAudioTracks().length);
    if (sources.length) {
      audioContext = new AudioContext(); await audioContext.resume();
      const mixed = audioContext.createMediaStreamDestination();
      sources.forEach(stream => audioContext.createMediaStreamSource(new MediaStream(stream.getAudioTracks())).connect(mixed));
      tracks.push(...mixed.stream.getAudioTracks());
    }
    captureID = crypto.randomUUID(); await post('/begin', '');
    screenRecorder = recorder(new MediaStream(tracks), screenChunks, '/screen');
    cameraRecorder = camera?.active ? recorder(camera, cameraChunks, '/camera') : null;
    started = performance.now(); screenRecorder.start(1000); cameraRecorder?.start(1000);
    heartbeat = setInterval(() => post('/heartbeat','').catch(() => {}),5000);
    state = 'recording'; $('badge').textContent = '● RECORDING'; $('record').hidden = true; $('pause').hidden = $('stop').hidden = false;
    timer = setInterval(() => {
      const seconds = Math.floor(((state === 'paused' ? pausedAt : performance.now()) - started - pausedDuration) / 1000);
      $('timer').textContent = `${String(Math.floor(seconds / 60)).padStart(2,'0')}:${String(seconds % 60).padStart(2,'0')}`;
    }, 200);
    status('Recording your selected source. Switch to the tab to begin your demo.');
  } catch (error) {
    if (captureID) { try { await post('/release',''); } catch {} captureID = null; }
    release(microphone); microphone = null; await audioContext?.close(); audioContext = null;
    state = 'setup'; setControls(false); $('record').disabled = false; status(error.message);
  }
}
function pause() {
  if (state === 'recording') {
    screenRecorder.pause(); cameraRecorder?.pause(); pausedAt = performance.now(); state = 'paused';
    $('pause').textContent = 'Resume'; $('badge').textContent = 'PAUSED'; status('Paused. This time will be excluded from your video.');
  } else if (state === 'paused') {
    pausedDuration += performance.now() - pausedAt; screenRecorder.resume(); cameraRecorder?.resume(); state = 'recording';
    $('pause').textContent = 'Pause'; $('badge').textContent = '● RECORDING'; status('Recording resumed.');
  }
}
function finishRecorder(value) {
  return new Promise(resolve => {
    if (!value || value.state === 'inactive') return resolve();
    value.addEventListener('stop',resolve,{once:true}); value.stop();
  });
}
async function stop() {
  if (state !== 'recording' && state !== 'paused') return;
  state = 'saving'; clearInterval(timer); clearInterval(heartbeat); $('stop').disabled = true; $('pause').hidden = true; $('badge').textContent = 'SAVING'; status('Finishing your recording and saving to FocusFlow…');
  await Promise.all([finishRecorder(screenRecorder),finishRecorder(cameraRecorder)]);
  if (camera) {
    const video = $('camera'), stage = $('preview');
    cameraPresentation = {x:(video.offsetLeft+video.clientWidth/2)/stage.clientWidth,y:(video.offsetTop+video.clientHeight/2)/stage.clientHeight,size:video.clientHeight/Math.min(stage.clientWidth,stage.clientHeight),shape:$('round').checked?'Circle':'Rounded',mirrored:$('mirror').checked};
  }
  release(display); release(camera); release(microphone); await audioContext?.close();
  screenBlob = new Blob(screenChunks,{type:screenRecorder.mimeType});
  if (cameraChunks.length) cameraBlob = new Blob(cameraChunks,{type:cameraRecorder.mimeType});
  $('download').hidden = false; $('downloadCamera').hidden = !cameraBlob;
  $('screen').srcObject = null; $('screen').src = URL.createObjectURL(screenBlob); $('screen').controls = true;
  $('camera').hidden = true;
  await uploads; await save();
}
async function save() {
  $('retry').hidden = true;
  try {
    if (uploadError) throw uploadError;
    await post('/finish',JSON.stringify({sourceName,cameraPresentation})); state = 'done'; $('badge').textContent = 'SAVED';
    status('Saved on your Mac. Switching to FocusFlow, where it is open and ready to edit.'); $('stop').hidden = true;
    // The app raises itself on handoff; this is the browser's half of it.
    document.body.classList.add('handed-off');
  } catch(error) {
    state = 'recovery'; $('badge').textContent = 'BACKUP READY';
    status(`Could not complete the handoff: ${error.message} Your recording is available below. Download it before closing this page.`);
    $('retry').hidden = !!uploadError;
  }
}
function download(blob, name) {
  if (!blob) return;
  const link = document.createElement('a'); link.href = URL.createObjectURL(blob); link.download = name;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(link.href),60000);
}
$('choose').onclick = $('change').onclick = choose; $('record').onclick = start; $('pause').onclick = pause; $('stop').onclick = stop; $('retry').onclick = save;
$('cam').onchange = $('cameras').onchange = configureCamera;
$('round').onchange = () => { $('camera').style.borderRadius = $('round').checked ? '50%' : '14px'; $('camera').style.aspectRatio = $('round').checked ? '1' : '1.45'; };
$('mirror').onchange = () => $('camera').style.transform = $('mirror').checked ? 'scaleX(-1)' : 'none';
$('camera').style.transform = 'scaleX(-1)';
$('download').onclick = () => download(screenBlob,'FocusFlow screen.mp4'); $('downloadCamera').onclick = () => download(cameraBlob,'FocusFlow camera.mp4');
$('camera').onpointerdown = event => { cameraDrag = {x:event.clientX,y:event.clientY,left:$('camera').offsetLeft,top:$('camera').offsetTop}; $('camera').setPointerCapture(event.pointerId); };
$('camera').onpointermove = event => {
  if (!cameraDrag) return;
  const video = $('camera'), bounds = $('preview');
  video.style.left = Math.max(0,Math.min(bounds.clientWidth-video.clientWidth,cameraDrag.left+event.clientX-cameraDrag.x))+'px';
  video.style.top = Math.max(0,Math.min(bounds.clientHeight-video.clientHeight,cameraDrag.top+event.clientY-cameraDrag.y))+'px';
  video.style.right = video.style.bottom = 'auto';
};
$('camera').onpointerup = $('camera').onpointercancel = () => { cameraDrag = null; };
window.addEventListener('beforeunload', event => { if (['starting','recording','paused','saving','recovery'].includes(state)) { event.preventDefault(); event.returnValue = ''; } });
if (!navigator.mediaDevices?.getDisplayMedia || !window.MediaRecorder) { $('choose').disabled = true; status('Open this page in a current version of Chrome.'); }
else { devices(); if (!token) { $('choose').disabled = true; status('Open Tab studio from FocusFlow → Record → Chrome tab. This page records into the app, so it has to be launched from there.'); } }

window.addEventListener('pagehide', () => { if (captureID && state !== 'done') { fetch('/release',{method:'POST',headers:{'X-FocusFlow-Token':token,'X-FocusFlow-Capture':captureID},body:'',keepalive:true}).catch(() => {}); } });
