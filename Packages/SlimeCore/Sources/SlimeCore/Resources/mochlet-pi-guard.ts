// Mochlet's original permission extension. API contract: Pi v1.4.0.
// This gates Pi tool calls; it is not an OS sandbox.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const reads = new Set(["read", "grep", "find", "ls"]);
  const readOnly = process.env.MOCHLET_PI_READ_ONLY === "1";
  let ready = false;
  pi.registerCommand("mochlet-guard-check", {
    description: "Verify the Mochlet host and session without model inference",
    handler: async (nonce, ctx) => {
      if (ctx.mode !== "rpc" || !nonce || nonce !== process.env.MOCHLET_PI_NONCE) return;
      ready = true;
      ctx.ui.notify(JSON.stringify({ mochletGuard: 1, nonce, cwd: ctx.cwd,
        sessionID: ctx.sessionManager.getSessionId(), sessionFile: ctx.sessionManager.getSessionFile(),
        tools: pi.getActiveTools(), readOnly }), "info");
    },
  });
  pi.on("tool_call", async (event, ctx) => {
    if (!ready || ctx.mode !== "rpc") return { block: true, reason: "Mochlet host has not verified this session." };
    if (reads.has(event.toolName)) return;
    if (readOnly) return { block: true, reason: "This Mochlet run uses read-only tools." };
    const input = JSON.stringify({ tool: event.toolName, input: event.input }, null, 2);
    if (input.length > 100_000) return { block: true, reason: "Tool request is too large to review." };
    try {
      const approved = await ctx.ui.confirm("Mochlet tool approval", input, { signal: ctx.signal, timeout: 300_000 });
      if (!approved) return { block: true, reason: "The user declined or the request expired." };
    } catch {
      return { block: true, reason: "Mochlet could not deliver this approval request." };
    }
  });
}
