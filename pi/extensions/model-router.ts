/**
 * Model Router Extension
 *
 * Default behaviour: Pi runs on its configured default model (codex-max).
 * The router only activates to switch TO the planning model (claude-opus-4-6)
 * when it detects explicit planning/analysis/review intent in the input.
 * After each task completes, auto-routing resets and the default (Codex) resumes.
 *
 * Commands:
 *   /mr                          Show current routing config
 *   /mr-use <model>              Force a specific model now (disables auto-routing)
 *   /mr-auto                     Re-enable auto-routing
 *   /mr-plan <model>             Set the default model for planning tasks
 *   /mr-code <model>             Set the default model for coding tasks
 *   /mr-list                     List all available models
 *
 * Defaults can also be set via environment variables:
 *   MODEL_ROUTER_PLANNING_PROVIDER / MODEL_ROUTER_PLANNING_MODEL
 *   MODEL_ROUTER_CODING_PROVIDER  / MODEL_ROUTER_CODING_MODEL
 *
 * Set MODEL_ROUTER=0 to disable entirely.
 *
 * Config is persisted to ~/.pi/agent/model-router.json
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";

// -- Config persistence -------------------------------------------------------

const CONFIG_PATH = join(homedir(), ".pi", "agent", "model-router.json");

interface RouterConfig {
  planningProvider: string;
  planningModel: string;
  codingProvider: string;
  codingModel: string;
}

function loadConfig(): RouterConfig {
  const defaults: RouterConfig = {
    planningProvider: process.env.MODEL_ROUTER_PLANNING_PROVIDER ?? "anthropic",
    planningModel:    process.env.MODEL_ROUTER_PLANNING_MODEL    ?? "claude-opus-4-6",
    codingProvider:   process.env.MODEL_ROUTER_CODING_PROVIDER   ?? "openai-codex",
    codingModel:      process.env.MODEL_ROUTER_CODING_MODEL      ?? "codex-max",
  };
  if (!existsSync(CONFIG_PATH)) return defaults;
  try {
    return { ...defaults, ...JSON.parse(readFileSync(CONFIG_PATH, "utf-8")) };
  } catch {
    return defaults;
  }
}

function saveConfig(cfg: RouterConfig): void {
  try {
    writeFileSync(CONFIG_PATH, JSON.stringify(cfg, null, 2) + "\n");
  } catch {
    // ignore write errors
  }
}

// -- Classification -----------------------------------------------------------

/** Only detect planning intent -- everything else stays on the default (Codex). */
const PLANNING_PATTERNS = [
  /\bplan\b/,
  /\bdesign\b/,
  /\barchitect\b/,
  /\bthink (through|about|over)\b/,
  /\banalyze\b/,
  /\breview\b/,
  /\bstrategy\b/,
  /\bhow should (we|i|the)\b/,
  /\bwhat (should|would|is the best)\b/,
  /\bexplain\b/,
  /\bunderstand\b/,
  /\bwhy (is|does|did|would)\b/,
  /\bcompare\b/,
  /\btrade.?off\b/,
  /\bconsider\b/,
  /\bpropose\b/,
];

function isPlanning(text: string): boolean {
  const lower = text.toLowerCase();
  return PLANNING_PATTERNS.some(p => p.test(lower));
}

// -- Helpers ------------------------------------------------------------------

/** Search available models by a loose query (id substring or name substring). */
function findByQuery(query: string, registry: any) {
  const q = query.toLowerCase().trim();
  const all = registry.getAvailable() as Array<{ provider: string; id: string; name: string }>;
  const exact = all.find(m => m.id === q);
  if (exact) return exact;
  const byId = all.filter(m => m.id.toLowerCase().includes(q));
  if (byId.length === 1) return byId[0];
  if (byId.length > 1) return { ambiguous: byId };
  const byName = all.filter(m => m.name.toLowerCase().includes(q));
  if (byName.length === 1) return byName[0];
  if (byName.length > 1) return { ambiguous: byName };
  return null;
}

function modelLabel(provider: string, modelId: string) {
  return `${provider}/${modelId}`;
}

// -- Extension ----------------------------------------------------------------

export default function (pi: ExtensionAPI) {
  if (process.env.MODEL_ROUTER === "0") return;

  let cfg = loadConfig();
  let autoEnabled = true;

  // -- Auto-routing on input --------------------------------------------------
  //
  // Strategy: Pi defaults to Codex (set in settings.json). The router only
  // switches TO Opus when it detects planning intent. Unclassified input stays
  // on the current model (Codex). After each task ends, auto-routing resets
  // and the next session will start on the default (Codex) again.

  pi.on("input", async (event, ctx) => {
    if (!autoEnabled) return { action: "continue" };

    const planning = isPlanning(event.text);

    if (planning) {
      // Switch to planning model (Opus)
      const current = ctx.model;
      if (current?.provider === cfg.planningProvider && current?.id === cfg.planningModel) {
        return { action: "continue" };
      }
      const target = ctx.modelRegistry.find(cfg.planningProvider, cfg.planningModel);
      if (!target) {
        console.log(`[model-router] planning model not found: ${cfg.planningProvider}/${cfg.planningModel}`);
        return { action: "continue" };
      }
      await pi.setModel(target);
      if (ctx.hasUI) ctx.ui.notify(`model-router: ${target.name} (planning)`, "info");
    } else {
      // Ensure we are on the coding model (Codex) -- handles the case where a
      // previous planning switch left us on Opus
      const current = ctx.model;
      if (current?.provider === cfg.codingProvider && current?.id === cfg.codingModel) {
        return { action: "continue" };
      }
      const target = ctx.modelRegistry.find(cfg.codingProvider, cfg.codingModel);
      if (!target) {
        console.log(`[model-router] coding model not found: ${cfg.codingProvider}/${cfg.codingModel}`);
        return { action: "continue" };
      }
      await pi.setModel(target);
      if (ctx.hasUI) ctx.ui.notify(`model-router: ${target.name} (coding)`, "info");
    }

    return { action: "continue" };
  });

  pi.on("agent_end", async () => {
    autoEnabled = true;
  });

  // -- Commands ---------------------------------------------------------------

  pi.registerCommand("mr", {
    description: "Show model-router status and current config",
    handler: async (_args, ctx) => {
      const current = ctx.model;
      const lines = [
        `model-router status`,
        `  auto-routing : ${autoEnabled ? "on" : "off (use /mr-auto to re-enable)"}`,
        `  current model: ${current ? modelLabel(current.provider, current.id) : "none"}`,
        `  planning     : ${modelLabel(cfg.planningProvider, cfg.planningModel)}`,
        `  coding       : ${modelLabel(cfg.codingProvider, cfg.codingModel)}`,
        ``,
        `Commands: /mr-use <model>  /mr-plan <model>  /mr-code <model>  /mr-auto  /mr-list`,
      ];
      if (ctx.hasUI) ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  pi.registerCommand("mr-list", {
    description: "List all available models",
    handler: async (_args, ctx) => {
      const models = (ctx.modelRegistry.getAvailable() as Array<{ provider: string; id: string; name: string }>)
        .sort((a, b) => a.provider.localeCompare(b.provider) || a.id.localeCompare(b.id));
      const lines = ["Available models:", ...models.map(m => `  ${m.provider}/${m.id}  (${m.name})`)];
      if (ctx.hasUI) ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  pi.registerCommand("mr-use", {
    description: "Force a specific model now and disable auto-routing until the task ends. Usage: /mr-use <model>",
    handler: async (args, ctx) => {
      if (!args.trim()) {
        if (ctx.hasUI) ctx.ui.notify("Usage: /mr-use <model-id or name>", "error");
        return;
      }
      const result = findByQuery(args, ctx.modelRegistry);
      if (!result) {
        if (ctx.hasUI) ctx.ui.notify(`No model found matching "${args}". Use /mr-list to see available models.`, "error");
        return;
      }
      if ("ambiguous" in result) {
        const opts = (result.ambiguous as any[]).map((m: any) => `  ${m.provider}/${m.id}`).join("\n");
        if (ctx.hasUI) ctx.ui.notify(`Ambiguous match for "${args}":\n${opts}`, "error");
        return;
      }
      autoEnabled = false;
      await pi.setModel(result as any);
      if (ctx.hasUI) ctx.ui.notify(`model-router: using ${(result as any).name} (auto-routing paused until task ends)`, "info");
    },
  });

  pi.registerCommand("mr-auto", {
    description: "Re-enable automatic model routing",
    handler: async (_args, ctx) => {
      autoEnabled = true;
      if (ctx.hasUI) ctx.ui.notify("model-router: auto-routing re-enabled", "info");
    },
  });

  pi.registerCommand("mr-plan", {
    description: "Set the default model for planning tasks. Usage: /mr-plan <model>",
    handler: async (args, ctx) => {
      if (!args.trim()) {
        if (ctx.hasUI) ctx.ui.notify(`Usage: /mr-plan <model-id or name>\nCurrent: ${modelLabel(cfg.planningProvider, cfg.planningModel)}`, "info");
        return;
      }
      const result = findByQuery(args, ctx.modelRegistry);
      if (!result) {
        if (ctx.hasUI) ctx.ui.notify(`No model found matching "${args}". Use /mr-list to see available models.`, "error");
        return;
      }
      if ("ambiguous" in result) {
        const opts = (result.ambiguous as any[]).map((m: any) => `  ${m.provider}/${m.id}`).join("\n");
        if (ctx.hasUI) ctx.ui.notify(`Ambiguous match for "${args}":\n${opts}`, "error");
        return;
      }
      const m = result as any;
      cfg = { ...cfg, planningProvider: m.provider, planningModel: m.id };
      saveConfig(cfg);
      if (ctx.hasUI) ctx.ui.notify(`model-router: planning model set to ${m.name} (${m.provider}/${m.id})`, "info");
    },
  });

  pi.registerCommand("mr-code", {
    description: "Set the default model for coding tasks. Usage: /mr-code <model>",
    handler: async (args, ctx) => {
      if (!args.trim()) {
        if (ctx.hasUI) ctx.ui.notify(`Usage: /mr-code <model-id or name>\nCurrent: ${modelLabel(cfg.codingProvider, cfg.codingModel)}`, "info");
        return;
      }
      const result = findByQuery(args, ctx.modelRegistry);
      if (!result) {
        if (ctx.hasUI) ctx.ui.notify(`No model found matching "${args}". Use /mr-list to see available models.`, "error");
        return;
      }
      if ("ambiguous" in result) {
        const opts = (result.ambiguous as any[]).map((m: any) => `  ${m.provider}/${m.id}`).join("\n");
        if (ctx.hasUI) ctx.ui.notify(`Ambiguous match for "${args}":\n${opts}`, "error");
        return;
      }
      const m = result as any;
      cfg = { ...cfg, codingProvider: m.provider, codingModel: m.id };
      saveConfig(cfg);
      if (ctx.hasUI) ctx.ui.notify(`model-router: coding model set to ${m.name} (${m.provider}/${m.id})`, "info");
    },
  });
}
