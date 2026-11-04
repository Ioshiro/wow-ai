'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { OmpLive } = require('../bridge/omp-live');
test('live attachment requires explicit identity and never sends into a replacement session', async () => {
 const directory=fs.mkdtempSync(path.join(os.tmpdir(),'wow-live-')), instance='a'.repeat(24), dir=path.join(directory,instance);fs.mkdirSync(dir);
 const metadata={version:1,instance,token:'b'.repeat(64),sessionId:'session-one',cwd:'/work',status:'idle',lastText:'desktop answer',revision:1,updatedAt:Date.now()};
 const write=()=>fs.writeFileSync(path.join(dir,'metadata.json'),JSON.stringify(metadata));write();
 const completions=[],bindings={};const live=new OmpLive({directory,bindings,save(){},publish(){},complete(job,status,text){completions.push({job,status,text});},timeoutMs:1000});
 try {
  await live.run('chat',{id:1,text:'/attach '+instance});assert.equal(bindings.chat.sessionId,'session-one');
  await live.run('chat',{id:2,text:'/watch'});assert.equal(completions.at(-1).text,'desktop answer');
  metadata.sessionId='session-two';write();await live.run('chat',{id:3,text:'do not send'});
  assert.equal(completions.at(-1).status,'error');assert.equal(fs.existsSync(path.join(dir,'command.json')),false);
  await live.run('chat',{id:4,text:'/attach '+instance});
  const running=live.run('chat',{id:5,text:'hello'});
  const command=JSON.parse(fs.readFileSync(path.join(dir,'command.json')));assert.equal(command.sessionId,'session-two');
  fs.writeFileSync(path.join(dir,'response.json'),JSON.stringify({id:command.id,ok:true}));live.tick();await running;
  metadata.status='idle';metadata.lastText='new reply';metadata.revision=2;write();live.tick();assert.equal(completions.at(-1).text,'new reply');
  await live.run('chat',{id:6,text:'/new'});assert.equal(completions.at(-1).status,'error');
  await live.run('chat',{id:7,text:'/detach'});assert.equal(bindings.chat,undefined);
 }finally{live.close();fs.rmSync(directory,{recursive:true,force:true});}
});
