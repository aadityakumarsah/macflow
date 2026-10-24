'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const nodes = new Map();
function node(id) {
  if (!nodes.has(id)) nodes.set(id, {checked:false,disabled:false,style:{},value:'',hidden:false,textContent:'',play:async()=>{},replaceChildren(){},add(){}});
  return nodes.get(id);
}
let nextStream, options;
const context = vm.createContext({
  document:{getElementById:node}, location:{hash:'#test-token'},history:{replaceState(){}},
  navigator:{mediaDevices:{enumerateDevices:async()=>[], getDisplayMedia:async value=>{options=value;return nextStream;}}},
  MediaRecorder:{isTypeSupported:()=>true},Option:function(){},
  window:{MediaRecorder:true,addEventListener(){}},console,URLSearchParams
});
vm.runInContext(fs.readFileSync('Sources/FocusFlow/BrowserRecorder/recorder.js','utf8'),context);
function stream(surface) {
  const track = {stopped:false,getSettings:()=>({displaySurface:surface,width:1280,height:720}),stop(){this.stopped=true;},addEventListener(){}};
  return {active:true,track,getTracks:()=>[track],getVideoTracks:()=>[track],getAudioTracks:()=>[]};
}
(async()=>{
  for (const surface of ['window','monitor',undefined]) {
    nextStream=stream(surface); await vm.runInContext('choose()',context);
    assert.equal(nextStream.track.stopped,true);
    assert.match(node('status').textContent,/Select a tab/);
    assert.equal(vm.runInContext('display',context),undefined);
  }
  nextStream=stream('browser'); await vm.runInContext('choose()',context);
  const accepted=nextStream;
  assert.equal(accepted.track.stopped,false); assert.equal(node('record').disabled,false);
  assert.equal(options.monitorTypeSurfaces,'exclude'); assert.equal(options.surfaceSwitching,'exclude');
  nextStream=stream('window'); await vm.runInContext('choose()',context);
  assert.equal(vm.runInContext('display',context),accepted); assert.equal(accepted.track.stopped,false);
  accepted.track.getSettings=()=>({displaySurface:'window'});
  await vm.runInContext('start()',context);
  assert.equal(accepted.track.stopped,true); assert.equal(node('record').disabled,true);
  console.log('PASS: tab-only selection, rejected-stream cleanup, previous-source preservation, start guard.');
})().catch(error=>{console.error(error);process.exitCode=1;});
