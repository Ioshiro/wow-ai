'use strict';

const { spawn } = require('node:child_process');
const { StringDecoder } = require('node:string_decoder');
const { TextDecoder } = require('node:util');

const DEFAULT_FRAME_LIMIT = 1024 * 1024;
const DEFAULT_REASSEMBLY_LIMIT = 64 * 1024 * 1024;

// Requests resolve to the complete response frame, including unsuccessful responses.
// onEvent receives every decoded logical frame, including ready and responses.
class OmpRpcSession {
  constructor({ file, args = [], cwd, env, timeoutMs = 30000, onEvent, onExit } = {}) {
    this.timeoutMs = timeoutMs;
    this.onEvent = onEvent;
    this.onExit = onExit;
    this.pending = new Map();
    this.sequence = 0;
    this.frameLimit = DEFAULT_FRAME_LIMIT;
    this.reassemblyLimit = DEFAULT_REASSEMBLY_LIMIT;
    this.buffer = Buffer.alloc(0);
    this.chunk = null;
    this.state = 'starting';
    this.exitNotified = false;
    this.child = spawn(file, args, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
    // Drain stderr without logging it: it can contain credentials or prompt data.
    this.child.stderr.resume();
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.startTimer = this._timer(() => this._fail(new Error('OMP RPC startup timed out')));
    this.child.stdout.on('data', data => this._receive(data));
    this.child.stdout.on('end', () => {
      if (this.buffer.length || this.chunk) this._fail(new Error('Incomplete OMP RPC frame'));
    });
    this.child.stdout.on('error', err => this._fail(err));
    this.child.stdin.on('error', err => this._fail(err));
    this.child.on('error', err => this._fail(err));
    this.child.on('close', (code, signal) => {
      clearTimeout(this.killTimer);
      this._fail(new Error(`OMP RPC process exited (code ${code}, signal ${signal})`), false);
      if (!this.exitNotified) {
        this.exitNotified = true;
        if (this.onExit) this.onExit(this.failure || new Error(`OMP RPC process exited (code ${code}, signal ${signal})`));
      }
    });
  }

  _timer(fn) {
    if (!(this.timeoutMs > 0)) return null;
    const timer = setTimeout(fn, this.timeoutMs);
    if (timer.unref) timer.unref();
    return timer;
  }

  _fail(error, kill = true) {
    if (this.state === 'failed' || this.state === 'closed') return;
    const wasStarting = this.state === 'starting' || this.state === 'negotiating';
    this.state = 'failed';
    this.failure = error;
    clearTimeout(this.startTimer);
    if (wasStarting) this.rejectReady(error);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    if (kill && !this.child.killed) this.child.kill();
  }

  _send(frame) {
    if (this.state === 'failed' || this.state === 'closed' || this.state === 'closing') {
      throw this.failure || new Error('OMP RPC session is closed');
    }
    const line = JSON.stringify(frame) + '\n';
    if (Buffer.byteLength(line) > this.frameLimit) throw new Error('OMP RPC input frame exceeds transport limit');
    this.child.stdin.write(line);
  }

  _request(type, fields) {
    return new Promise((resolve, reject) => {
      const id = `rpc-${++this.sequence}`;
      const timer = this._timer(() => {
        if (this.pending.delete(id)) reject(new Error(`OMP RPC ${type} request timed out`));
      });
      this.pending.set(id, { resolve, reject, timer });
      try {
        this._send({ ...fields, type, id });
      } catch (error) {
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error);
      }
    });
  }

  async request(type, fields = {}) {
    await this.ready;
    return this._request(type, fields);
  }

  // UI replies must remain available while startup or another request is waiting.
  respond(response) {
    this._send({ ...response, type: 'extension_ui_response' });
  }

  _receive(data) {
    if (this.state === 'failed' || this.state === 'closed') return;
    try {
      this.buffer = this.buffer.length ? Buffer.concat([this.buffer, data]) : data;
      let newline;
      while ((newline = this.buffer.indexOf(10)) !== -1) {
        if (newline + 1 > this.frameLimit) throw new Error('OMP RPC frame exceeds transport limit');
        const bytes = this.buffer.subarray(0, newline);
        this.buffer = this.buffer.subarray(newline + 1);
        new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        const decoder = new StringDecoder('utf8');
        const text = decoder.write(bytes) + decoder.end();
        const frame = JSON.parse(text);
        if (!frame || typeof frame !== 'object' || Array.isArray(frame)) throw new Error('Invalid OMP RPC frame');
        this._frame(frame);
      }
      if (this.buffer.length >= this.frameLimit) throw new Error('OMP RPC frame exceeds transport limit');
    } catch (error) {
      this._fail(error);
    }
  }

  _frame(frame) {
    if (frame.type === 'rpc_chunk') {
      if (this.state !== 'ready' && this.state !== 'closing') throw new Error('Unexpected OMP RPC chunk');
      const { chunkId, index, count, byteLength, data } = frame;
      if (typeof chunkId !== 'string' || !chunkId || !Number.isSafeInteger(index) || !Number.isSafeInteger(count) || count < 1 || index < 0 || index >= count || !Number.isSafeInteger(byteLength) || byteLength < 1 || byteLength > this.reassemblyLimit || typeof data !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)) throw new Error('Invalid OMP RPC chunk');
      if (!this.chunk) {
        if (index !== 0 || count > byteLength) throw new Error('Invalid OMP RPC chunk sequence');
        this.chunk = { chunkId, count, byteLength, next: 0, length: 0, parts: [] };
      }
      const chunk = this.chunk;
      if (chunk.chunkId !== chunkId || chunk.count !== count || chunk.byteLength !== byteLength || chunk.next !== index) throw new Error('Interrupted OMP RPC chunk sequence');
      const part = Buffer.from(data, 'base64');
      if (!part.length || part.toString('base64') !== data) throw new Error('Invalid OMP RPC chunk data');
      chunk.length += part.length;
      if (chunk.length > byteLength) throw new Error('OMP RPC chunk length exceeded');
      chunk.parts.push(part);
      chunk.next++;
      if (chunk.next === count) {
        if (chunk.length !== byteLength) throw new Error('Invalid OMP RPC reassembled length');
        this.chunk = null;
        const bytes = Buffer.concat(chunk.parts, chunk.length);
        const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
        const decoded = JSON.parse(text);
        if (!decoded || typeof decoded !== 'object' || Array.isArray(decoded) || decoded.type === 'rpc_chunk') throw new Error('Invalid OMP RPC reassembled frame');
        this._frame(decoded);
      }
      return;
    }
    if (this.chunk) throw new Error('Interrupted OMP RPC chunk sequence');
    if (frame.type === 'ready') {
      if (this.state !== 'starting' || !Array.isArray(frame.supportedProtocolVersions) || !frame.supportedProtocolVersions.includes(2) || !Number.isSafeInteger(frame.maxFrameBytes) || frame.maxFrameBytes < 1 || !Number.isSafeInteger(frame.maxReassembledFrameBytes) || frame.maxReassembledFrameBytes < 1) throw new Error('OMP RPC protocol v2 unavailable');
      this.frameLimit = Math.min(frame.maxFrameBytes, DEFAULT_FRAME_LIMIT);
      this.reassemblyLimit = Math.min(frame.maxReassembledFrameBytes, DEFAULT_REASSEMBLY_LIMIT);
      this.state = 'negotiating';
      this._request('negotiate_protocol', { protocolVersion: 2 }).catch(error => this._fail(error));
    }
    if (frame.type === 'response' && typeof frame.id === 'string') {
      const pending = this.pending.get(frame.id);
      if (pending) {
        if (this.state === 'negotiating' && frame.command === 'negotiate_protocol') {
          if (!frame.success) throw new Error('OMP RPC protocol negotiation failed');
          this.state = 'ready';
          clearTimeout(this.startTimer);
          this.resolveReady();
        }
        this.pending.delete(frame.id);
        clearTimeout(pending.timer);
        pending.resolve(frame);
      }
    }
    if (this.onEvent) this.onEvent(frame);
  }

  // Close stdin first and keep reading stdout; force termination if EOF stalls.
  close() {
    if (this.state === 'closed' || this.state === 'failed' || this.state === 'closing') return;
    const starting = this.state === 'starting' || this.state === 'negotiating';
    this.state = 'closing';
    clearTimeout(this.startTimer);
    const error = new Error('OMP RPC session closed');
    this.failure = error;
    if (starting) this.rejectReady(error);
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.child.stdin.end();
    this.killTimer = setTimeout(() => { if (!this.child.killed) this.child.kill(); }, 3000);
    if (this.killTimer.unref) this.killTimer.unref();
  }
}

module.exports = { OmpRpcSession };
