import { randomBytes } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";

const randomHex = (bytes: number) => randomBytes(bytes).toString("hex");

// The IPC directory is private to this extension instance. The token is never
// exposed outside that directory; Windows relies on inherited user ACLs.
export default function wowAI(pi: ExtensionAPI) {
  const instance = randomHex(12);
  const token = randomHex(32);
  const base = process.env.WOW_AI_LIVE_DIR || path.resolve(import.meta.dirname, "../bridge/live");
  const directory = path.join(base, instance);
  const processed = new Map<string, { id: string; ok: boolean; error?: string }>();
  const approvals = new Set<string>();
  const asks = new Set<string>();
  let sessionId = "";
  let lastText = "";
  let revision = 0;
  let running = false;
  let closed = false;
  let timer: ReturnType<ExtensionContext["setInterval"]> | undefined;
  let latestContext: ExtensionContext;
  let activeTick: Promise<void> | undefined;
  let metadataWrites = Promise.resolve();

  async function privateDirectory(dir: string) {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    await chmod(dir, 0o700).catch(() => {});
  }

  async function atomicJson(name: string, value: unknown) {
    const tmp = path.join(directory, `.${name}.${randomHex(12)}.tmp`);
    try {
      await writeFile(tmp, JSON.stringify(value), { mode: 0o600, flag: "wx" });
      await chmod(tmp, 0o600).catch(() => {});
      await rename(tmp, path.join(directory, name));
    } finally {
      await rm(tmp, { force: true }).catch(() => {});
    }
  }

  function syncSession(ctx: ExtensionContext) {
    const current = ctx.sessionManager.getSessionId();
    if (current !== sessionId) {
      sessionId = current;
      lastText = "";
      revision++;
      approvals.clear();
      asks.clear();
      running = false;
    }
  }

  function jobActive(snapshot: unknown): boolean {
    if (!snapshot || typeof snapshot !== "object") return false;
    const value = snapshot as Record<string, unknown>;
    // Snapshots may contain counts or job collections depending on host version.
    for (const key of ["running", "pending", "active", "runningCount", "pendingCount", "activeCount"]) {
      const item = value[key];
      if (item === true || (typeof item === "number" && item > 0) || (Array.isArray(item) && item.length > 0)) return true;
    }
    for (const key of ["jobs", "tasks"]) {
      const items = value[key];
      if (Array.isArray(items) && items.some(item => item && typeof item === "object" && ["running", "pending", "queued"].includes(String((item as Record<string, unknown>).status)))) return true;
    }
    return false;
  }

  function status(ctx: ExtensionContext) {
    if (approvals.size || asks.size || ctx.getPendingPlanReview?.()) return "waiting_input";
    if (running || !ctx.isIdle() || ctx.hasPendingMessages() || jobActive(ctx.getAsyncJobSnapshot())) return "working";
    return "idle";
  }

  async function publish() {
    const write = metadataWrites.catch(() => {}).then(async () => {
      if (closed) return;
      syncSession(latestContext);
      await atomicJson("metadata.json", {
        version: 1, instance, token, sessionId, cwd: latestContext.cwd, pid: process.pid,
        pane: process.env.TERN_PANE || "", status: status(latestContext), lastText, revision,
        updatedAt: Date.now(),
      });
    });
    metadataWrites = write;
    await write;
  }

  async function handleCommand(ctx: ExtensionContext) {
    let command: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(await readFile(path.join(directory, "command.json"), "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return;
      command = parsed as Record<string, unknown>;
    } catch (error) {
      // Atomic writers can briefly leave no file; tolerate malformed partial writes too.
      if ((error as NodeJS.ErrnoException).code === "ENOENT" || error instanceof SyntaxError) return;
      throw error;
    }
    if (typeof command.id !== "string" || !command.id) return;
    let response = processed.get(command.id);
    if (!response) {
      response = { id: command.id, ok: false };
      try {
        syncSession(ctx);
        if (command.token !== token) throw new Error("Invalid token");
        if (command.sessionId !== sessionId) throw new Error("Session changed; reconnect before sending");
        if (!["prompt", "steer", "followup", "abort"].includes(String(command.type))) throw new Error("Unknown command type");
        if (command.type === "abort") {
          await ctx.abort();
        } else {
          if (typeof command.text !== "string" || !command.text.trim()) throw new Error("Text is required");
          if (command.text.trimStart().startsWith("/")) throw new Error("Slash commands are available only in the desktop session");
          // Check immediately before dispatch; never deliver an old-session command.
          syncSession(ctx);
          if (command.sessionId !== sessionId) throw new Error("Session changed; reconnect before sending");
          const busy = !ctx.isIdle() || ctx.hasPendingMessages();
          lastText = "";
          if (busy && command.type === "followup") await pi.sendUserMessage(command.text, { deliverAs: "followUp" });
          else if (busy && command.type === "steer") await pi.sendUserMessage(command.text, { deliverAs: "steer" });
          else await pi.sendUserMessage(command.text);
        }
        response.ok = true;
      } catch (error) {
        response.error = error instanceof Error ? error.message : String(error);
      }
      processed.set(command.id, response);
      if (processed.size > 256) processed.delete(processed.keys().next().value!);
    }
    await atomicJson("response.json", response);
  }

  async function tick() {
    if (closed || activeTick) return;
    activeTick = (async () => {
      await handleCommand(latestContext);
      if (!closed) await publish();
    })();
    try { await activeTick; } finally { activeTick = undefined; }
  }

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.agent?.kind === 'sub') return;
    latestContext = ctx;
    await mkdir(base, { recursive: true, mode: 0o700 });
    await privateDirectory(directory);
    syncSession(ctx);
    await publish();
    timer = ctx.setInterval(tick, 1000);
  });
  pi.on('session_before_switch', async () => { approvals.clear(); asks.clear(); });
  pi.on("session_switch", async (_event, ctx) => {
    if (!timer) return;
    latestContext = ctx;
    syncSession(ctx);
    await publish();
  });
  pi.on("session_branch", async (_event, ctx) => {
    if (!timer) return;
    latestContext = ctx;
    syncSession(ctx);
    await publish();
  });
  pi.on("agent_start", (_event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx); running = true; lastText = "";
  });
  pi.on("agent_end", (_event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx); running = false; revision++;
  });
  pi.on("message_end", (event, ctx) => {
    if (!timer) return;
    latestContext = ctx;
    syncSession(ctx);
    if (event.message.role !== "assistant") return;
    lastText = event.message.content.filter(block => block.type === "text").map(block => block.text).join("\n");
    revision++;
  });
  pi.on("tool_approval_requested", (event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx); approvals.add(event.toolCallId);
  });
  pi.on("tool_approval_resolved", (event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx); approvals.delete(event.toolCallId);
  });
  pi.on("tool_execution_start", (event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx);
    if (event.toolName === "ask") asks.add(event.toolCallId);
  });
  pi.on("tool_execution_end", (event, ctx) => {
    if (!timer) return;
    latestContext = ctx; syncSession(ctx); asks.delete(event.toolCallId);
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    if (!timer) return;
    closed = true;
    if (timer) ctx.clearTimer(timer);
    await activeTick?.catch(() => {});
    await metadataWrites.catch(() => {});
    await rm(directory, { recursive: true, force: true });
  });
}
