// Demo Launcher canvas: a thin Copilot SDK adapter around launcher/core.mjs.
// Everything SDK-specific lives in this file, so if the SDK changes, the standalone
// launcher (launcher/server.mjs) keeps working.

import { homedir } from "node:os";
import { join } from "node:path";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import {
    configure, listen, loadTemplates, startRun, findRun, cancelRun, listRuns, summary,
    cleanup, sessionPrompt, seedPromptFor, askAgent, LauncherError,
} from "../../../launcher/core.mjs";

let session = null;

configure({
    stateDir: join(process.env.COPILOT_HOME || join(homedir(), ".copilot"), "extensions", "demo-launcher", "artifacts"),
    agent: {
        async send(prompt) {
            if (!session) throw new LauncherError("no_session", "Extension is not connected to a session.");
            await session.send({ prompt });
        },
    },
    log: (message, level) => session?.log(message, { level }),
});

const handler = (fn) => async (ctx) => {
    try {
        return await fn(ctx);
    } catch (e) {
        throw e instanceof LauncherError ? new CanvasError(e.code, e.message) : e;
    }
};

const templateKeys = (() => {
    try {
        return loadTemplates().map((t) => t.key);
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
                    handler: handler(async () => loadTemplates()),
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
                    handler: handler(async (ctx) => summary(startRun(ctx.input || {}))),
                },
                {
                    name: "get_run",
                    description: "Get status, links, and full log of a run (latest by default).",
                    inputSchema: runIdInput,
                    handler: handler(async (ctx) => findRun(ctx.input?.runId)),
                },
                {
                    name: "list_runs",
                    description: "List recent demo runs with their status and links.",
                    handler: handler(async () => listRuns().map((r) => summary(r)).map(({ logTail, ...r }) => r)),
                },
                {
                    name: "cleanup_preview",
                    description: "List demo-generated repos older than the cutoff that cleanup would delete (shown in the canvas).",
                    inputSchema: {
                        type: "object",
                        properties: {
                            owner: { type: "string", description: "Account or org; defaults to the logged-in account." },
                            olderThanHours: { type: "integer", minimum: 0, description: "Age cutoff in hours (default 24; 0 = all)." },
                        },
                    },
                    handler: handler(async (ctx) => cleanup.preview(ctx.input || {})),
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
                    handler: handler(async (ctx) => cleanup.remove(ctx.input || {})),
                },
                {
                    name: "run_with_ensemble",
                    description: "For demos with a seed prompt: open a new autopilot session in the demo repo that runs the seed prompt with the Ensemble model (latest run by default).",
                    inputSchema: runIdInput,
                    handler: handler(async (ctx) => {
                        const run = findRun(ctx.input?.runId);
                        if (run.status !== "succeeded" || run.result.deleted) throw new LauncherError("not_ready", "That demo repo is not ready.");
                        await askAgent(sessionPrompt(run, "ensemble"));
                        return { sent: true, seedPrompt: seedPromptFor(run) };
                    }),
                },
                {
                    name: "cancel",
                    description: "Stop an in-progress demo run (latest by default).",
                    inputSchema: runIdInput,
                    handler: handler(async (ctx) => cancelRun(findRun(ctx.input?.runId).id)),
                },
            ],
            open: async (ctx) => {
                const base = await listen();
                const t = ctx.input?.template;
                return { title: "Demo Launcher", url: t ? `${base}?template=${encodeURIComponent(t)}` : base };
            },
        }),
    ],
});
