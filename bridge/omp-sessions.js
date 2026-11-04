'use strict';
const crypto = require('crypto');
const { OmpRpcSession } = require('./omp-rpc');
const { ompParser } = require('./agents');

// One owner per dedicated chat. Never reuse a process after a workspace or
// launch-configuration change; session IDs remain the bridge's persisted source.
class OmpSessions {
  constructor({ publish, complete, saveSession, log }) {
    Object.assign(this, { publish, complete, saveSession, log });
    this.sessions = new Map();
  }
  async run(key, job, launch) {
    let entry = this.sessions.get(key);
    const identity = launch.identity;
    if (entry && (entry.identity !== identity || job.newSession)) { this.drop(key); entry = null; }
    if (!entry) {
      entry = { identity, job, parser: ompParser(), progress: [], dialogs: new Map(), session: launch.resume || '', closed: false };
      this.sessions.set(key, entry);
      entry.client = new OmpRpcSession({ ...launch,
        onEvent: ev => { this.event(entry, ev).catch(error => { const job = entry.job; this.drop(key); if (!job?.finished) this.end(entry, 'error', error.message); }); },
        onExit: error => {
          if (this.sessions.get(key) === entry) this.sessions.delete(key);
          if (!entry.closed && entry.job && !entry.job.finished) this.end(entry, 'error', error?.message || 'omp process exited');
        },
      });
    }
    entry.job = job;
    entry.progress = [];
    entry.result = null;
    entry.dialogs.clear();
    entry.promptEnded = false;
    entry.commandOutput = '';
    entry.parser = ompParser();
    entry.timer = setTimeout(() => { this.drop(key); this.end(entry, 'error', 'omp exceeded the configured timeout'); }, launch.timeoutMs || 1800000);
    entry.keepalive = setInterval(() => this.update(entry), 45000);
    this.update(entry, 'Starting interactive omp session...');
    try {
      await entry.client.ready;
      if (!entry.initialized) {
        entry.initialized = true;
        // Older omp releases fall back to select/editor dialogs.
        await entry.client.request('set_ask_dialog', { enabled: true });
      }
      if (entry.closed || job.finished) return;
      if (job.text.trim() === '/new') {
        const response = await entry.client.request('new_session');
        if (!response.success || response.data?.cancelled) throw new Error(response.error || 'New session cancelled.');
        await this.refreshState(entry);
        this.end(entry, 'done', 'Started a new omp session in this project.');
        return;
      }
      const response = await entry.client.request('prompt', { message: job.text });
      if (!response.success) throw new Error(response.error || 'omp refused the prompt');
      if (response.data?.agentInvoked === false) {
        await this.refreshState(entry);
        if (!job.finished) this.end(entry, 'done', entry.commandOutput || 'Command completed.');
      }
    } catch (error) {
      if (this.sessions.get(key) === entry) this.drop(key);
      if (!job.finished && entry.job === job) this.end(entry, 'error', error.message);
    }
  }
  update(entry, text) {
    if (!entry.job || entry.job.finished) return;
    if (text) { entry.progress.push(String(text)); if (entry.progress.length > 10) entry.progress.shift(); }
    this.publish(entry.job, { text: entry.progress.join('\n'), session: entry.session, ui: [...entry.dialogs.values()][0]?.dto });
  }
  async event(entry, ev) {
    if (entry.closed) return;
    const parsed = entry.parser.feed(ev);
    if (parsed.session) entry.session = parsed.session;
    for (const text of parsed.progress) this.update(entry, text);
    if (parsed.done) entry.result = parsed.done;
    if (ev.type === 'extension_ui_request') {
      if (ev.method === 'cancel') {
        for (const [token, dialog] of entry.dialogs) if (dialog.request.id === ev.targetId) entry.dialogs.delete(token);
      } else if (['ask', 'select', 'confirm', 'input', 'editor'].includes(ev.method)) {
        if (!entry.job || entry.job.finished || ev.secret) {
          entry.client.respond({ id: ev.id, cancelled: true });
          return;
        }
        const token = crypto.randomBytes(12).toString('hex');
        const options = (values, details) => (values || []).map((label, i) => typeof label === 'string' ? { label, description: details?.[i]?.description || '' } : { label: label.label, description: label.description || '', preview: label.preview || '' });
        const dto = { id: token, method: ev.method, title: ev.title || '', message: ev.message || '', value: ev.prefill || ev.initialValue || '', options: options(ev.options, ev.optionDetails), questions: (ev.questions || []).map(q => ({ id: q.id, question: q.question, header: q.header || '', multi: !!q.multi, recommended: q.recommended === undefined ? undefined : q.recommended + 1, options: options(q.options) })) };
        entry.dialogs.set(token, { request: ev, dto });
      } else if (ev.method === 'notify') {
        entry.commandOutput = [entry.commandOutput, ev.message].filter(Boolean).join('\n');
        this.update(entry, ev.message);
      }
      this.update(entry);
    } else if (ev.type === 'command_output') {
      entry.commandOutput = (entry.commandOutput || '') + (ev.text || ev.output || '');
      this.update(entry, ev.text || ev.output);
    } else if (ev.type === 'prompt_result') {
      entry.promptEnded = true;
      if (ev.status === 'error' || ev.status === 'aborted') entry.result = { text: ev.error?.message || 'Operation cancelled.', error: true };
      if (ev.sessionSettled) await this.finishSettled(entry);
    } else if (ev.type === 'session_settled') {
      await this.finishSettled(entry);
    }
    if (ev.type === 'session_info_update') await this.refreshState(entry);
  }
  async finishSettled(entry) {
    if (!entry.promptEnded || !entry.job || entry.job.finished) return;
    const job = entry.job;
    await this.refreshState(entry);
    if (entry.job !== job || job.finished) return;
    const result = entry.result;
    this.end(entry, result?.error ? 'error' : 'done', result?.text || entry.commandOutput || 'Command completed.');
  }
  end(entry, status, text) {
    clearTimeout(entry.timer);
    clearInterval(entry.keepalive);
    entry.dialogs.clear();
    if (entry.session && entry.job) this.saveSession(entry.job, entry.session);
    this.complete(entry.job, status, text, entry.session);
  }
  async control(key, job) {
    const entry = this.sessions.get(key);
    if (!entry || !entry.job || entry.job.finished || entry.job.id !== job.target) return false;
    if (job.control === 'ui') {
      const [token, action, ...values] = job.text.split('\x1f');
      const dialog = entry.dialogs.get(token);
      if (!dialog) return false;
      const request = dialog.request;
      let answer = { id: request.id };
      if (action === 'cancel') answer.cancelled = true;
      else if (action === 'confirm' && request.method === 'confirm' && ['true', 'false'].includes(values[0])) answer.confirmed = values[0] === 'true';
      else if (action === 'select' && request.method === 'select') {
        const index = Number(values[0]);
        if (!Number.isInteger(index) || index < 1 || index > request.options.length) return false;
        answer.value = request.options[index - 1];
      } else if (action === 'input' && ['input', 'editor'].includes(request.method)) answer.value = values.join('\x1f');
      else if (action === 'ask' && request.method === 'ask' && values.length === request.questions.length) {
        answer.answers = [];
        for (let n = 0; n < values.length; n++) {
          const match = /^([\d,]*):([0-9a-f]*)$/i.exec(values[n]);
          if (!match || match[2].length % 2) return false;
          const q = request.questions[n];
          const indices = match[1] ? match[1].split(',').map(Number) : [];
          const customInput = Buffer.from(match[2], 'hex').toString('utf8').trim();
          if (new Set(indices).size !== indices.length || indices.some(i => !Number.isInteger(i) || i < 1 || i > q.options.length) || (!q.multi && (indices.length > 1 || (indices.length && customInput)))) return false;
          answer.answers.push({ id: q.id, selectedOptions: indices.map(i => q.options[i - 1].label), ...(customInput ? { customInput } : {}) });
        }
      } else return false;
      entry.client.respond(answer);
      entry.dialogs.delete(token);
      this.update(entry);
    } else {
      const type = { abort: 'abort', steer: 'steer', followup: 'follow_up' }[job.control];
      if (!type) return false;
      const response = await entry.client.request(type, type === 'abort' ? {} : { message: job.text });
      if (!response.success) { this.update(entry, response.error || 'Control request refused'); return false; }
      if (type !== 'abort') this.update(entry, `${type === 'steer' ? 'Steering' : 'Follow-up'} message received.`);
    }
    return true;
  }
  drop(key) {
    const entry = this.sessions.get(key);
    if (!entry) return;
    entry.closed = true;
    clearTimeout(entry.timer);
    clearInterval(entry.keepalive);
    entry.dialogs.clear();
    this.sessions.delete(key);
    entry.client.close();
  }
  async refreshState(entry) {
    const response = await entry.client.request('get_state');
    if (response.success && response.data?.sessionId) {
      entry.session = response.data.sessionId;
      this.saveSession(entry.job, entry.session);
    }
  }
  close() { for (const key of this.sessions.keys()) this.drop(key); }
}
module.exports = { OmpSessions };
