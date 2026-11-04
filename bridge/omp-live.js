'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function readJson(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } }
class OmpLive {
  constructor({ directory, bindings, events = {}, save, publish, complete, changed = () => {}, timeoutMs = 1800000 }) {
    Object.assign(this, { directory, bindings, events, save, publish, complete, changed, timeoutMs });
    this.active = new Map();
    this.pending = new Map();
    this.timer = setInterval(() => this.tick(), 250);
    this.timer.unref();
  }
  list() {
    let names; try { names = fs.readdirSync(this.directory); } catch { return []; }
    return names.filter(n => /^[a-f0-9]{24}$/.test(n)).map(n => this.metadata(n)).filter(Boolean);
  }
  metadata(instance) {
    if (!/^[a-f0-9]{24}$/.test(instance || '')) return null;
    const value = readJson(path.join(this.directory, instance, 'metadata.json'));
    if (!value || value.version !== 1 || value.instance !== instance || typeof value.sessionId !== 'string' || typeof value.token !== 'string' || !/^[a-f0-9]{64}$/.test(value.token) || !Number.isFinite(value.updatedAt) || Date.now() - value.updatedAt > 6000) return null;
    return value;
  }
  send(metadata, type, text = '') {
    if (this.pending.has(metadata.instance)) return Promise.reject(new Error('Another command is awaiting acknowledgment; retry shortly.'));
    const id = crypto.randomBytes(12).toString('hex');
    const dir = path.join(this.directory, metadata.instance);
    const command = { id, token: metadata.token, sessionId: metadata.sessionId, type, text };
    return new Promise((resolve, reject) => {
      this.pending.set(metadata.instance, { id, resolve, reject, until: Date.now() + 5000 });
      const tmp = path.join(dir, `${id}.tmp`);
      try { fs.writeFileSync(tmp, JSON.stringify(command), { mode: 0o600, flag: 'wx' }); fs.renameSync(tmp, path.join(dir, 'command.json')); }
      catch (error) { this.pending.delete(metadata.instance); try { fs.unlinkSync(tmp); } catch {} reject(error); }
    });
  }
  async run(key, job) {
    const text = job.text.trim();
    const finish = (status, body) => this.complete(job, status, body);
    if (text === '/sessions') {
      const sessions = this.list();
      finish('done', sessions.length ? sessions.map(m => `${m.instance}\n${m.cwd}\n${m.status} · ${m.sessionId}\n${String(m.lastText || '').slice(0, 180)}`).join('\n\n') + '\n\n/attach <instance> continuously follows this instance until /detach.' : 'No shared omp sessions found. Load omp-extension/wow-ai.ts in the desired omp process.');
      return;
    }
    if (text === '/detach') { const old = this.bindings[key]; if (old) this.emit(key, old, 'detached', 'Detached.'); delete this.bindings[key]; this.save(); finish('done', 'Detached. The desktop agent keeps running.'); return; }
    const attach = /^\/attach\s+([a-f0-9]{24})$/.exec(text);
    if (attach) {
      const metadata = this.metadata(attach[1]);
      if (!metadata) { finish('error', 'Shared instance is unavailable. Send /sessions for the current list.'); return; }
      const occupied = Object.entries(this.bindings).find(([other, binding]) => other !== key && binding.instance === metadata.instance);
      if (occupied) { finish('error', 'This omp is already attached to another WoW chat. Detach that chat first.'); return; }
      this.bindings[key] = { instance: metadata.instance, sessionId: metadata.sessionId, chat: job.chat || '', revision: metadata.revision, status: metadata.status };
      this.emit(key, this.bindings[key], 'attached', 'Continuously following the desktop agent.');
      this.save();
      finish('done', `Attached to ${metadata.cwd}\nSession: ${metadata.sessionId}\n${metadata.lastText || 'No completed assistant reply yet.'}\n\nContinuously following until /detach. Slash commands and dialogs stay in Tern.`);
      return;
    }
    const binding = this.bindings[key];
    const metadata = binding && this.metadata(binding.instance);
    if (!metadata) { finish('error', 'Not connected to a live shared omp. Send /sessions, then /attach <instance>.'); return; }
    if (binding.sessionId !== metadata.sessionId) {
      finish('error', `The desktop changed session. Reattach explicitly with /attach ${metadata.instance}; no message was sent.`);
      return;
    }
    if (text.startsWith('/')) { finish('error', 'Live attachment accepts ordinary text, /sessions, /attach and /detach. Attached instances are followed continuously; slash commands and dialogs stay in Tern.'); return; }
    const entry = { job, binding, revision: metadata.revision, until: Date.now() + this.timeoutMs, accepted: false };
    this.active.set(key, entry);
    this.publish(job, { text: metadata.status === 'waiting_input' ? 'Input required in Tern. Alt-tab to answer; this chat will keep following.' : 'Following the live desktop agent...', session: metadata.sessionId });
    try {
      await this.send(metadata, 'prompt', job.text);
      if (this.active.get(key) !== entry) return;
      entry.accepted = true;
      this.active.delete(key);
      finish('done', 'Message delivered to the desktop agent. Its reply will arrive automatically.');
    } catch (error) { if (this.active.get(key) === entry) { this.active.delete(key); finish('error', error.message + '\nDelivery may be uncertain after a timeout; check Tern before resending.'); } }
  }
  async control(key, job) {
    const entry = this.active.get(key);
    if (entry && entry.job.id !== job.target) return false;
    const binding = entry?.binding || this.bindings[key];
    const metadata = binding && this.metadata(binding.instance);
    if (!metadata || metadata.sessionId !== binding.sessionId) return false;
    const type = { steer: 'steer', followup: 'followup', abort: 'abort' }[job.control];
    if (!type || (type !== 'abort' && job.text.trim().startsWith('/'))) return false;
    await this.send(metadata, type, job.text);
    return true;
  }
  tick() {
    for (const [instance, pending] of this.pending) {
      const response = readJson(path.join(this.directory, instance, 'response.json'));
      if (response?.id === pending.id) {
        this.pending.delete(instance);
        if (response.ok) pending.resolve(response); else pending.reject(new Error(response.error || 'Shared omp refused the command'));
      } else if (Date.now() > pending.until) { this.pending.delete(instance); pending.reject(new Error('Shared omp did not acknowledge the command')); }
    }
    for (const [key, binding] of Object.entries(this.bindings)) {
      const metadata = this.metadata(binding.instance);
      if (!metadata || metadata.sessionId !== binding.sessionId) {
        const status = metadata ? 'session_changed' : 'disconnected';
        if (binding.status !== status) { binding.status = status; this.emit(key, binding, status, metadata ? 'Desktop session changed. Attach again to follow the new conversation.' : 'Desktop agent disconnected. Waiting for the same instance.'); this.save(); }
        continue;
      }
      if (!Number.isFinite(binding.revision)) binding.revision = metadata.revision;
      const replies = Array.isArray(metadata.replies) ? metadata.replies : [];
      for (const reply of replies) {
        if (Number.isSafeInteger(reply.revision) && reply.revision > binding.revision) {
          this.emit(key, binding, 'done', String(reply.text || 'The desktop turn ended without a text reply.'), reply.revision);
          binding.revision = reply.revision;
          this.save();
        }
      }
      if (binding.status !== metadata.status) { binding.status = metadata.status; this.emit(key, binding, metadata.status, metadata.status === 'waiting_input' ? 'Input required in Tern. Alt-tab to answer.' : metadata.status === 'working' ? 'Desktop agent is working...' : 'Desktop agent is idle.'); this.save(); }
    }
    for (const [key, entry] of this.active) {
      const metadata = this.metadata(entry.binding.instance);
      let status, text;
      if (!metadata) { status = 'error'; text = 'Shared omp disconnected. Its desktop process was not restarted or resumed.'; }
      else if (metadata.sessionId !== entry.binding.sessionId) { status = 'error'; text = 'Desktop session changed. Reattach explicitly before sending more messages.'; }
      else if (Date.now() > entry.until) { status = 'error'; text = 'Stopped following after the configured timeout. The desktop agent keeps running.'; }
      else if (entry.accepted) { status = 'done'; text = 'Message delivered to the desktop agent.'; }
      if (status) { this.active.delete(key); this.complete(entry.job, status, text, metadata?.sessionId); }
      else {
        const detail = metadata.status === 'waiting_input' ? 'Input required in Tern. Alt-tab to answer.' : metadata.status === 'working' ? 'Desktop agent is working...' : 'Waiting for the desktop agent...';
        if (entry.detail !== detail || Date.now() - (entry.publishedAt || 0) > 45000) { entry.detail = detail; entry.publishedAt = Date.now(); this.publish(entry.job, { text: detail, session: metadata.sessionId }); }
      }
    }
  }
  emit(key, binding, status, text, revision) {
    if (status !== 'done') for (const [oldId, event] of Object.entries(this.events)) if (event.chat === (binding.chat || key.replace(/^chat:/, '')) && event.status !== 'done') delete this.events[oldId];
    const id = revision === undefined ? crypto.randomBytes(12).toString('hex') : `${binding.instance}:${binding.sessionId}:${revision}`;
    this.events[id] = { id, chat: binding.chat || key.replace(/^chat:/, ''), status, text, session: binding.sessionId, instance: binding.instance };
    this.save();
    this.changed();
  }
  acknowledge(id) { if (this.events[id]) { delete this.events[id]; this.save(); this.changed(); } }
  snapshot() { return Object.values(this.events); }
  refresh() {
    for (const [key, binding] of Object.entries(this.bindings)) {
      const metadata = this.metadata(binding.instance);
      const status = !metadata ? 'disconnected' : metadata.sessionId !== binding.sessionId ? 'session_changed' : 'attached';
      this.emit(key, binding, status, status === 'attached' ? 'Continuously following the desktop agent.' : 'Desktop instance unavailable or session changed; inspect Tern.');
    }
  }
  drop(key) { this.active.delete(key); const chat = this.bindings[key]?.chat; for (const [id, event] of Object.entries(this.events)) if (event.chat === chat) delete this.events[id]; }
  close() { clearInterval(this.timer); for (const pending of this.pending.values()) pending.reject(new Error('Bridge stopped')); this.pending.clear(); this.active.clear(); }
}
module.exports = { OmpLive };
