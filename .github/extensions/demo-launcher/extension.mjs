// Demo Launcher canvas for the Copilot app and CLI: pick a template from config.json, run
// create-repo in the background, watch the log, then jump into the new repo (app session,
// VS Code, GitHub). The host-neutral logic lives in core.mjs; vscode/ is the VS Code host.

import { homedir } from "node:os";
import { join } from "node:path";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import { createLauncher, LauncherError } from "./core.mjs";

const STORE_FILE = join(process.env.COPILOT_HOME || join(homedir(), ".copilot"), "extensions", "demo-launcher", "artifacts", "runs.json");

let session = null;

const launcher = createLauncher({
    storeFile: STORE_FILE,
    host: {
        name: "app",
        features: { appSessions: true, seedRun: "fusion" },
        log: (message, level) => session?.log(message, { level }),
        async sendPrompt(prompt) {
            if (!session) throw new LauncherError("no_session", "Extension is not connected to a session.");
            await session.send({ prompt });
        },
    },
});

// Canvas actions report failures as CanvasError so the agent gets the code and message.
const action = (fn) => async (ctx) => {
    try {
        return await fn(ctx.input || {});
    } catch (e) {
        throw e instanceof LauncherError ? new CanvasError(e.code, e.message) : e;
    }
};

const templateKeys = (() => {
    try {
        return launcher.loadTemplates().map((t) => t.key);
    } catch {
        return undefined;
    }
})();

const runIdInput = { type: "object", properties: { runId: { type: "string", description: "Run id; defaults to the latest run." } } };

session = await joinSession({
    canvases: [
        createCanvas({
            id: "demo-launcher",
            displayName: "Demo Launcher",
            description: "Pick a booth demo from config.json, create it in the background with create-repo, and jump into the new repo, PR, or session.",
            inputSchema: {
                type: "object",
                properties: { template: { type: "string", description: "Optional template key to preselect." } },
            },
            actions: [
                {
                    name: "list_templates",
                    description: "List demo templates from config.json.",
                    handler: action(() => launcher.loadTemplates()),
                },
                {
                    name: "launch",
                    description: "Create a demo repo in the background (runs create-repo non-interactively).",
                    inputSchema: {
                        type: "object",
                        required: ["template"],
                        properties: {
                            template: { type: "string", ...(templateKeys ? { enum: templateKeys } : {}) },
                            owner: { type: "string", description: "Account or org to create the repo in." },
                            noClone: { type: "boolean", description: "Skip the local clone in ~/repos." },
                            openBrowser: { type: "boolean", description: "Let the script open browser tabs." },
                        },
                    },
                    handler: action((input) => launcher.startRun(input)),
                },
                {
                    name: "get_run",
                    description: "Get status, links, and full log of a run (latest by default).",
                    inputSchema: runIdInput,
                    handler: action((input) => launcher.getRun(input.runId)),
                },
                {
                    name: "list_runs",
                    description: "List recent demo runs with their status and links.",
                    handler: action(() => launcher.listRuns()),
                },
                {
                    name: "cleanup_preview",
                    description: "List demo-generated repos older than the cutoff that cleanup would delete (shown in the canvas).",
                    inputSchema: {
                        type: "object",
                        properties: {
                            owner: { type: "string", description: "Account or org; defaults to the logged-in account." },
                            olderThanHours: { type: "integer", minimum: 0, description: "Age cutoff in hours (default 72; 0 = all)." },
                        },
                    },
                    handler: action((input) => launcher.cleanupPreview(input)),
                },
                {
                    name: "cleanup_delete",
                    description: "Delete repos from the current cleanup preview. Only call after the user confirmed the list.",
                    inputSchema: {
                        type: "object",
                        properties: {
                            repos: { type: "array", items: { type: "string" }, description: "owner/name repos from the preview; defaults to all of them." },
                            removeClones: { type: "boolean", description: "Also delete matching local clones in ~/repos." },
                        },
                    },
                    handler: action((input) => launcher.cleanupDelete(input)),
                },
                {
                    name: "run_with_fusion",
                    description: "For demos with a seed prompt: open a new autopilot session in the demo repo that runs the seed prompt with the GitHub Copilot Fusion model (latest run by default).",
                    inputSchema: runIdInput,
                    handler: action((input) => launcher.runSeed(input.runId, { requireSuccess: true })),
                },
                {
                    name: "cancel",
                    description: "Stop an in-progress demo run (latest by default).",
                    inputSchema: runIdInput,
                    handler: action((input) => launcher.cancelRun(input.runId)),
                },
            ],
            open: async (ctx) => {
                const base = await launcher.ensureServer();
                const t = ctx.input?.template;
                return { title: "Demo Launcher", url: t ? `${base}?template=${encodeURIComponent(t)}` : base };
            },
        }),
    ],
});
