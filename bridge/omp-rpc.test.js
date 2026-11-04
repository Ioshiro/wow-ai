'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { OmpRpcSession } = require('./omp-rpc');

const server = `
const readline = require('node:readline');
const emit = frame => process.stdout.write(JSON.stringify(frame) + '\\n');
emit({type:'ready',protocolVersion:1,supportedProtocolVersions:[1,2],maxFrameBytes:1048576,maxReassembledFrameBytes:67108864});
let waiting;
readline.createInterface({input:process.stdin}).on('line', line => {
  const frame = JSON.parse(line);
  if (frame.type === 'negotiate_protocol') {
    emit({type:'response',id:frame.id,command:frame.type,success:true});
    const bytes = Buffer.from(JSON.stringify({type:'message_end',text:'caffè ☕'}));
    const halves = [bytes.subarray(0, 7),bytes.subarray(7)];
    halves.forEach((part,index) => emit({type:'rpc_chunk',chunkId:'x',index,count:2,byteLength:bytes.length,data:part.toString('base64')}));
  } else if (frame.type === 'prompt') {
    waiting = frame;
    emit({type:'extension_ui_request',id:'dialog',method:'confirm'});
  } else if (frame.type === 'extension_ui_response') {
    emit({type:'response',id:waiting.id,command:'prompt',success:true});
    emit({type:'prompt_result',id:waiting.id,status:'success'});
  } else if (frame.type === 'abort') {
    emit({type:'response',id:frame.id,command:'abort',success:true});
  }
});
`;

test('negotiates, reassembles chunks and handles UI while requests are pending', async () => {
  const events = [];
  const session = new OmpRpcSession({file:process.execPath,args:['-e',server],timeoutMs:2000,onEvent:frame => events.push(frame)});
  try {
    await session.ready;
    const prompt = session.request('prompt', {message:'hello'});
    const abort = session.request('abort');
    await abort;
    session.respond({id:'dialog',confirmed:false});
    assert.equal((await prompt).success, true);
    assert.ok(events.some(frame => frame.type === 'message_end' && frame.text === 'caffè ☕'));
    assert.ok(events.some(frame => frame.type === 'extension_ui_request'));
  } finally { session.close(); }
});

test('rejects pending requests on an interrupted chunk sequence', async () => {
  const badServer = server.replace("halves.forEach((part,index) => emit({type:'rpc_chunk',chunkId:'x',index,count:2,byteLength:bytes.length,data:part.toString('base64')}));", "emit({type:'rpc_chunk',chunkId:'x',index:0,count:2,byteLength:bytes.length,data:halves[0].toString('base64')}); emit({type:'session_settled'});");
  const session = new OmpRpcSession({file:process.execPath,args:['-e',badServer],timeoutMs:2000});
  try {
    await session.ready;
    await assert.rejects(session.request('prompt', {message:'hello'}), /Interrupted/);
  } finally { session.close(); }
});
