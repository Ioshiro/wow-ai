'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { OmpSessions } = require('../bridge/omp-sessions');
const server = `
const readline = require('node:readline');
const emit = e => console.log(JSON.stringify(e));
let session = 'session-1', ticket;
emit({type:'ready',supportedProtocolVersions:[1,2],maxFrameBytes:1048576,maxReassembledFrameBytes:67108864});
readline.createInterface({input:process.stdin}).on('line', line => {
 const f = JSON.parse(line);
 const response = data => emit({type:'response',id:f.id,command:f.type,success:true,data});
 if (f.type === 'get_state') return response({sessionId:session});
 if (f.type === 'new_session') { session = 'session-2'; return response({cancelled:false}); }
 if (f.type === 'prompt') {
  ticket = f.id;
  response({});
  emit({type:'extension_ui_request',id:'ui-1',method:'ask',questions:[{id:'choice',question:'Pick',options:[{label:'A'},{label:'B'}]}]});
 } else if (f.type === 'extension_ui_response') {
  const message = {role:'assistant',content:[{type:'text',text:f.answers[0].selectedOptions[0]}],stopReason:'stop'};
  emit({type:'message_end',message});
  emit({type:'agent_end',messages:[message]});
  emit({type:'prompt_result',id:ticket,status:'completed',sessionSettled:false});
  setTimeout(() => emit({type:'session_settled'}), 20);
 } else response({});
});`;

test('dedicated process retains ownership across turns, rejects stale answers and waits for settlement', async () => {
 let wake;
 const updates = [], completions = [], saved = [];
 const manager = new OmpSessions({publish: (job, value) => { updates.push({job, ...value}); wake?.(); }, complete: (job, status, text) => { job.finished = true; completions.push({job,status,text}); wake?.(); }, saveSession: (_, id) => saved.push(id), log: () => {}});
 const until = predicate => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('Expected state not reached')), 3000);
  const check = () => { if (predicate()) { clearTimeout(timer); resolve(); } else wake = check; };
  check();
 });
 const launch = {file:process.execPath,args:['-e',server],cwd:process.cwd(),env:process.env,identity:'same',timeoutMs:3000};
 try {
  const job = {id:1,text:'question'};
  await manager.run('chat',job,launch);
  await until(() => updates.some(x => x.ui));
  const ui = updates.find(x => x.ui).ui;
  assert.equal(await manager.control('chat',{target:99,control:'ui',text:ui.id+'\x1fask\x1f1:'}),false);
  assert.equal(await manager.control('chat',{target:1,control:'ui',text:ui.id+'\x1fask\x1f3:'}),false);
  assert.equal(await manager.control('chat',{target:1,control:'ui',text:ui.id+'\x1fask\x1f2:'}),true);
  assert.equal(await manager.control('chat',{target:1,control:'ui',text:ui.id+'\x1fask\x1f1:'}),false);
  await until(() => completions.length === 1);
  assert.equal(completions[0].text,'B');
  const processId = manager.sessions.get('chat').client.child.pid;
  await manager.run('chat',{id:2,text:'/new'},launch);
  assert.equal(manager.sessions.get('chat').client.child.pid,processId);
  assert.equal(saved.at(-1),'session-2');
  assert.equal(completions[1].status,'done');
 } finally { manager.close(); }
});

test('four projects can await independent questions without leaking answers', async () => {
 const updates = new Map(), completed = new Map();
 let wake = () => {};
 const manager = new OmpSessions({publish(job,v){ if(v.ui) updates.set(job.id,v.ui); wake(); },complete(job,status,text){job.finished=true;completed.set(job.id,{status,text});wake();},saveSession(){},log(){}});
 const until = predicate => new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error('Parallel state timeout')),5000); const check=()=>{if(predicate()){clearTimeout(timer);resolve();}else wake=check;};check();});
 const launch = {file:process.execPath,args:['-e',server],cwd:process.cwd(),env:process.env,identity:'parallel',timeoutMs:5000};
 try {
  await Promise.all([1,2,3,4].map(id=>manager.run('project-'+id,{id,text:'question'},launch)));
  await until(()=>updates.size===4);
  assert.equal(new Set([...manager.sessions.values()].map(e=>e.client.child.pid)).size,4);
  await Promise.all([1,2,3,4].map(id=>manager.control('project-'+id,{target:id,control:'ui',text:updates.get(id).id+'\x1fask\x1f'+(id%2?1:2)+':'})));
  await until(()=>completed.size===4);
  for(const id of [1,2,3,4]) assert.deepEqual(completed.get(id),{status:'done',text:id%2?'A':'B'});
 } finally {manager.close();}
});
