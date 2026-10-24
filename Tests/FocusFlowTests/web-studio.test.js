'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync('docs/studio/recorder.js', 'utf8');

function studio(hash, capturedCursor = 'never') {
  const nodes = new Map();
  const requests = [];
  const captureOptions = [], constraints = [];
  const downloads = [];
  const classes = [];
  const node = id => {
    if (!nodes.has(id)) nodes.set(id, {
      checked: false, disabled: false, hidden: false, value: '', textContent: '',
      style: {}, play: async () => {}, replaceChildren() {}, add() {}, remove() {}, addEventListener(name, callback) { this[name] = callback; },
    });
    return nodes.get(id);
  };
  node('connection-help').hidden = true;
  const track = {
    stopped: false,
    getSettings: () => ({ displaySurface: 'browser', width: 1280, height: 720, cursor: capturedCursor }),
    applyConstraints: async value => { constraints.push(value); },
    stop() { this.stopped = true; },
    addEventListener() {},
  };
  const stream = {
    active: true,
    getTracks: () => [track],
    getVideoTracks: () => [track],
    getAudioTracks: () => [],
  };
  class FakeRecorder {
    static isTypeSupported() { return true; }
    constructor() { this.state = 'inactive'; this.mimeType = 'video/mp4'; this.listeners = new Map(); }
    addEventListener(name, callback) {
      if (!this.listeners.has(name)) this.listeners.set(name, []);
      this.listeners.get(name).push(callback);
    }
    emit(name, event) { for (const callback of this.listeners.get(name) || []) callback(event); }
    start() { this.state = 'recording'; }
    stop() {
      this.emit('dataavailable', { data: new Blob(['sample video'], { type: this.mimeType }) });
      this.state = 'inactive';
      this.emit('stop', {});
    }
  }
  const context = vm.createContext({
    console, Blob, URLSearchParams, Option: function () {},
    location: { hash, hostname: 'macflow-delta.vercel.app', pathname: '/studio/' },
    history: { replaceState() {} },
    document: {
      getElementById: node,
      body: { classList: { add: value => classes.push(value) }, append() {} },
      createElement: () => ({ click() { downloads.push(this.download); }, remove() {} }),
    },
    navigator: { mediaDevices: {
      enumerateDevices: async () => [],
      getDisplayMedia: async options => { captureOptions.push(options); return stream; },
    } },
    window: { MediaRecorder: FakeRecorder, addEventListener() {} },
    MediaRecorder: FakeRecorder,
    MediaStream: class { constructor(tracks) { this.tracks = tracks; } getAudioTracks() { return []; } },
    URL: { createObjectURL: () => 'blob:sample', revokeObjectURL() {} },
    crypto: { randomUUID: () => '00000000-0000-4000-8000-000000000001' },
    performance: { now: () => 1000 },
    setInterval: () => 1, clearInterval() {}, setTimeout() {},
    fetch: async (url, options) => { requests.push({ url, options }); return { ok: true, text: async () => '' }; },
  });
  vm.runInContext(source, context);
  return { context, node, requests, downloads, classes, track, captureOptions, constraints };
}

(async () => {
  const direct = studio('');
  assert.equal(direct.node('choose').disabled, false);
  await vm.runInContext('choose()', direct.context);
  assert.equal(direct.context.location.href, 'focusflow://record-tab');
  assert.equal(direct.node('connection-help').hidden, false);
  assert.match(direct.node('status').textContent, /Opening FocusFlow/);
  direct.node('record-locally').click();
  assert.equal(direct.node('connection-help').hidden, true);
  await vm.runInContext('choose()', direct.context);
  assert.equal(direct.node('record').disabled, false);
  await vm.runInContext('start()', direct.context);
  await vm.runInContext('stop()', direct.context);
  assert.equal(direct.node('badge').textContent, 'READY');
  assert.equal(direct.node('download').hidden, false);
  assert.match(direct.node('status').textContent, /Download it below/);
  direct.node('download').onclick();
  assert.deepEqual(direct.downloads, ['FocusFlow screen.mp4']);
  assert.equal(direct.requests.length, 0);

  const connected = studio('#session-token&port=4321');
  await vm.runInContext('choose()', connected.context);
  await vm.runInContext('start()', connected.context);
  await vm.runInContext('stop()', connected.context);
  assert.deepEqual(connected.requests.map(request => request.url), [
    'http://127.0.0.1:4321/begin',
    'http://127.0.0.1:4321/screen',
    'http://127.0.0.1:4321/finish',
  ]);
  assert.equal(connected.node('badge').textContent, 'SAVED');
  assert.equal(JSON.parse(connected.requests.at(-1).options.body).cursorIncluded, false);
  assert.equal(connected.captureOptions[0].video.cursor, 'never');
  assert.equal(connected.constraints[0].cursor, 'never');
  assert.match(connected.node('status').textContent, /Switching to FocusFlow/);
  assert.deepEqual(connected.classes, ['handed-off']);
  const baked = studio('#session-token&port=4321', 'always');
  await vm.runInContext('choose()', baked.context);
  assert.match(baked.node('status').textContent, /suppress its own overlay/);
  await vm.runInContext('start()', baked.context);
  await vm.runInContext('stop()', baked.context);
  assert.equal(JSON.parse(baked.requests.at(-1).options.body).cursorIncluded, true);
  console.log('PASS: direct studio opens FocusFlow; browser-only mode downloads locally; connected recording hands off cursor metadata.');
})().catch(error => { console.error(error); process.exitCode = 1; });
