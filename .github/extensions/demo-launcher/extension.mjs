// Demo Launcher canvas: pick a template from config.json, run create-repo in the
// background, watch the log, then jump into the new repo (app session, VS Code, GitHub).

import { createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, existsSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import { createCleanup } from "./cleanup.mjs";

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(EXT_DIR, "..", "..", "..");
const CONFIG_FILE = join(REPO_ROOT, "config.json");
const UI_FILE = join(EXT_DIR, "ui.html");
const STORE_DIR = join(process.env.COPILOT_HOME || join(homedir(), ".copilot"), "extensions", "demo-launcher", "artifacts");
const STORE_FILE = join(STORE_DIR, "runs.json");
const MAX_RUNS = 30;
const MAX_LOG_CHARS = 200_000;

// ---------- config ----------

function loadTemplates() {
    const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
    return (config.repos || []).map((r) => ({
        key: r.key,
        displayName: r.display_name || r.key,
        description: r.description_short || "",
        hint: r.workflow_hint || "",
        workflow: r.workflow,
        template: `${r.template_org || config.org}/${r.template}`,
        owner: r.owner === "org" ? config.org : r.owner || null,
        requiresClone: r.workflow === "branch_and_codespace",
        answerKey: answerKeyPath(r.key),
    }));
}

// Presenter-only notes (e.g. resources/octocart/ANSWER_KEY.md). They stay in this repo
// and are never copied into demo repos, so the canvas opens them from here.
function answerKeyPath(key) {
    const file = join(REPO_ROOT, "resources", String(key), "ANSWER_KEY.md");
    return existsSync(file) ? file : null;
}

// The app may inject its own GH_TOKEN (without scopes like `codespace` or `delete_repo`),
// which would override the user's `gh auth login`. Prefer the stored login, like a terminal run.
function scriptEnv(extra = {}) {
    const env = { ...process.env, NO_COLOR: "1", ...extra };
    delete env.GITHUB_ACTIONS;
    if (env.GH_TOKEN || env.GITHUB_TOKEN) {
        const stored = { ...env };
        delete stored.GH_TOKEN;
        delete stored.GITHUB_TOKEN;
        const probe = spawnSync("gh", ["auth", "token", "-h", "github.com"], { env: stored, stdio: "ignore", timeout: 10000 });
        if (probe.status === 0) return stored;
    }
    return env;
}

function scriptCommand(args) {
    return process.platform === "win32"
        ? { cmd: "powershell.exe", args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(REPO_ROOT, "create-repo.ps1"), ...args.win] }
        : { cmd: "bash", args: [join(REPO_ROOT, "create-repo.sh"), ...args.sh] };
}

// ---------- run store (durable across reloads) ----------

let runs = [];
try {
    runs = JSON.parse(readFileSync(STORE_FILE, "utf8"));
    for (const r of runs) {
        if (r.status === "running") {
            r.status = "interrupted";
            r.finishedAt = r.finishedAt || new Date().toISOString();
        }
    }
} catch {
    runs = [];
}

let saveTimer = null;
function persist() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
        try {
            mkdirSync(STORE_DIR, { recursive: true });
            writeFileSync(STORE_FILE, JSON.stringify(runs.slice(0, MAX_RUNS), null, 2));
        } catch {
            // best effort
        }
    }, 250);
}

const processes = new Map(); // runId -> ChildProcess
const clients = new Set(); // SSE responses

function summary(run, { withLog = false } = {}) {
    const { log, ...rest } = run;
    return withLog ? run : { ...rest, logTail: log.slice(-4000) };
}

function broadcast(event, data) {
    const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const res of clients) res.write(payload);
}

function parseLine(run, line) {
    const r = run.result;
    let m;
    if ((m = line.match(/Repository created successfully: (\S+)/))) {
        r.repo = m[1];
        r.repoUrl = `https://github.com/${m[1]}`;
    }
    if ((m = line.match(/Repository cloned to (.+)$/))) r.clonePath = m[1].trim();
    if ((m = line.match(/Target owner: (\S+)/))) r.owner = m[1];
    if ((m = line.match(/Game is live: (\S+)/))) r.pagesUrl = m[1];
    if ((m = line.match(/Codespace created/))) r.codespace = true;
    for (const u of line.matchAll(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/(pull|issues)\/(\d+)/g)) {
        const list = u[1] === "pull" ? r.prs : r.issues;
        if (!list.some((x) => x.url === u[0])) {
            list.push({ number: Number(u[2]), url: u[0], title: null });
        }
    }
    if ((m = line.match(/Creating PR: (.+?) \(base:/))) run._pendingPrTitle = m[1];
    if ((m = line.match(/PR #(\d+) created: (\S+)/))) {
        const pr = r.prs.find((p) => p.url === m[2]);
        if (pr && run._pendingPrTitle) pr.title = run._pendingPrTitle;
    }
    if ((m = line.match(/Copilot Code Review requested on PR #(\d+)( \(via REST API\))?/))) {
        const pr = r.prs.find((p) => p.number === Number(m[1]));
        if (pr) pr.copilotReview = m[2] ? "rest" : "requested";
    }
    if ((m = line.match(/Could not request Copilot Code Review on PR #(\d+)/))) {
        const pr = r.prs.find((p) => p.number === Number(m[1]));
        if (pr) pr.copilotReview = "failed";
    }
    if ((m = line.match(/Pull requests: (https:\/\/\S+)/))) r.pullsUrl = m[1];
}

function readOutputs(file) {
    const out = {};
    if (!existsSync(file)) return out;
    for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
        const i = line.indexOf("=");
        if (i > 0) out[line.slice(0, i)] = line.slice(i + 1);
    }
    return out;
}

function startRun({ template, owner, noClone = false, openBrowser = false }) {
    const tpl = loadTemplates().find((t) => t.key === template);
    if (!tpl) throw new CanvasError("unknown_template", `Unknown template '${template}'.`);
    if (noClone && tpl.requiresClone) throw new CanvasError("invalid_options", `${tpl.displayName} needs a local clone.`);

    const isWin = process.platform === "win32";
    const outDir = mkdtempSync(join(tmpdir(), "demo-launcher-"));
    const outFile = join(outDir, "outputs.txt");
    const args = isWin
        ? ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(REPO_ROOT, "create-repo.ps1"), "-Template", template]
        : [join(REPO_ROOT, "create-repo.sh"), "--template", template];
    if (owner) args.push(...(isWin ? ["-Owner", owner] : ["--owner", owner]));
    if (noClone) args.push(isWin ? "-NoClone" : "--no-clone");
    const cmd = isWin ? "powershell.exe" : "bash";

    const run = {
        id: randomUUID().slice(0, 8),
        template,
        templateName: tpl.displayName,
        options: { owner: owner || null, noClone, openBrowser },
        command: `${cmd} ${args.map((a) => (a.includes(" ") ? `"${a}"` : a)).join(" ")}`,
        status: "running",
        exitCode: null,
        startedAt: new Date().toISOString(),
        finishedAt: null,
        result: { repo: null, repoUrl: null, owner: null, clonePath: null, pagesUrl: null, topPrUrl: null, pullsUrl: null, prs: [], issues: [], codespace: false, answerKey: tpl.answerKey },
        log: "",
    };
    runs.unshift(run);
    runs = runs.slice(0, MAX_RUNS);

    const env = scriptEnv({ GITHUB_OUTPUT: outFile });
    if (!openBrowser) env.DEMO_NO_BROWSER = "1";
    else delete env.DEMO_NO_BROWSER;

    const child = spawn(cmd, args, { cwd: REPO_ROOT, env, stdio: ["ignore", "pipe", "pipe"] });
    processes.set(run.id, child);

    let partial = "";
    const onData = (chunk) => {
        const text = chunk.toString();
        run.log = (run.log + text).slice(-MAX_LOG_CHARS);
        partial += text;
        const lines = partial.split(/\r?\n/);
        partial = lines.pop();
        for (const l of lines) parseLine(run, l);
        broadcast("run", summary(run));
        persist();
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);

    const finish = (code, err) => {
        if (run.status !== "running") return;
        processes.delete(run.id);
        if (partial) parseLine(run, partial);
        if (err) run.log += `\n❌ ${err.message}\n`;
        const outputs = readOutputs(outFile);
        if (outputs.repo_name) {
            run.result.repo = outputs.repo_name;
            run.result.repoUrl = outputs.repo_url || `https://github.com/${outputs.repo_name}`;
        }
        if (outputs.top_pr_url) run.result.topPrUrl = outputs.top_pr_url;
        if (outputs.pages_url) run.result.pagesUrl = run.result.pagesUrl || outputs.pages_url;
        if (outputs.pulls_url) run.result.pullsUrl = outputs.pulls_url;
        rmSync(outDir, { recursive: true, force: true });
        run.exitCode = code;
        run.status = run.cancelled ? "cancelled" : code === 0 ? "succeeded" : "failed";
        run.finishedAt = new Date().toISOString();
        delete run._pendingPrTitle;
        broadcast("run", summary(run));
        persist();
        session?.log(
            run.status === "succeeded"
                ? `Demo ready: ${run.templateName} → ${run.result.repoUrl}`
                : `Demo ${run.status}: ${run.templateName} (exit ${code ?? "?"})`,
            { level: run.status === "succeeded" ? "info" : "warning" },
        );
    };
    child.on("error", (e) => finish(null, e));
    child.on("close", (code) => finish(code));

    broadcast("run", summary(run));
    persist();
    return run;
}

function cancelRun(id) {
    const child = processes.get(id);
    const run = runs.find((r) => r.id === id);
    if (!child || !run) throw new CanvasError("not_running", "That run is not in progress.");
    run.cancelled = true;
    child.kill("SIGTERM");
    return summary(run);
}

function findRun(id) {
    const run = id ? runs.find((r) => r.id === id) : runs[0];
    if (!run) throw new CanvasError("not_found", id ? `No run '${id}'.` : "No runs yet.");
    return run;
}

// ---------- cleanup ----------

const cleanup = createCleanup({
    repoRoot: REPO_ROOT,
    scriptEnv,
    scriptCommand,
    broadcast,
    onRepoDeleted(repo) {
        for (const r of runs) {
            if (r.result.repo?.toLowerCase() === repo.toLowerCase()) {
                r.result.deleted = true;
                broadcast("run", summary(r));
            }
        }
        persist();
    },
    log: (message, level) => session?.log(message, { level }),
});

// ---------- follow-ups ----------

function sessionPrompt(run, kind, target) {
    const r = run.result;
    if (!r.repo) throw new CanvasError("no_repo", "This run did not create a repository.");
    const where = r.clonePath
        ? `It is cloned locally at ${r.clonePath} (use that path for create_project).`
        : `It is not cloned locally; create the project from the GitHub repo ${r.repo}.`;
    if (kind === "pr") {
        return `[Demo Launcher] Open a Copilot app session for pull request #${target} in ${r.repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_pr_session (repo_full_name "${r.repo}", pr_number ${target}). Don't start any work in it (omit kickoff), then navigate me to it.`;
    }
    if (kind === "issue") {
        return `[Demo Launcher] Open a Copilot app session for issue #${target} in ${r.repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_issue_session (repo_full_name "${r.repo}", issue_number ${target}). Don't start any work in it (omit kickoff), then navigate me to it.`;
    }
    return `[Demo Launcher] I just created the demo repo ${r.repo} (${run.templateName}). ${where} Add it as a project in this app (create_project) if it isn't one already, create a new idle session in it (create_session with that project_id, no kickoff, detached: true), then navigate me to that session.`;
}

async function askAgent(prompt) {
    if (!session) throw new CanvasError("no_session", "Extension is not connected to a session.");
    await session.send({ prompt });
}

function which(bin) {
    const paths = (process.env.PATH || "").split(process.platform === "win32" ? ";" : ":");
    const extra = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin"];
    for (const p of [...paths, ...extra]) {
        for (const name of process.platform === "win32" ? [`${bin}.cmd`, `${bin}.exe`] : [bin]) {
            if (existsSync(join(p, name))) return join(p, name);
        }
    }
    return null;
}

function openInVSCode(run) {
    const r = run.result;
    if (!r.clonePath || !existsSync(r.clonePath)) throw new CanvasError("no_clone", "No local clone for this demo.");
    const code = which("code");
    let child;
    if (code) child = spawn(code, [r.clonePath], { detached: true, stdio: "ignore", shell: process.platform === "win32" });
    else if (process.platform === "darwin") child = spawn("open", ["-a", "Visual Studio Code", r.clonePath], { detached: true, stdio: "ignore" });
    else throw new CanvasError("no_vscode", "Could not find the 'code' command.");
    child.on("error", () => {});
    child.unref();
    return { opened: r.clonePath };
}

function openAnswerKey(run) {
    const file = answerKeyPath(run.template);
    if (!file) throw new CanvasError("no_answer_key", "This demo has no presenter answer key.");
    const code = which("code");
    let child;
    if (code) child = spawn(code, [file], { detached: true, stdio: "ignore", shell: process.platform === "win32" });
    else if (process.platform === "darwin") child = spawn("open", ["-t", file], { detached: true, stdio: "ignore" });
    else if (process.platform === "win32") child = spawn("notepad.exe", [file], { detached: true, stdio: "ignore" });
    else child = spawn("xdg-open", [file], { detached: true, stdio: "ignore" });
    child.on("error", () => {});
    child.unref();
    return { opened: file };
}

// ---------- HTTP server (one shared loopback server for all panels) ----------

let serverPromise = null;
function readBody(req) {
    return new Promise((resolve, reject) => {
        let data = "";
        req.on("data", (c) => {
            data += c;
            if (data.length > 1e5) req.destroy();
        });
        req.on("end", () => {
            try {
                resolve(data ? JSON.parse(data) : {});
            } catch (e) {
                reject(e);
            }
        });
        req.on("error", reject);
    });
}

function json(res, status, body) {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
}

async function handle(req, res) {
    const url = new URL(req.url, "http://127.0.0.1");
    try {
        if (req.method === "GET" && url.pathname === "/") {
            res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" });
            return res.end(readFileSync(UI_FILE, "utf8"));
        }
        if (req.method === "GET" && url.pathname === "/api/state") {
            return json(res, 200, { templates: loadTemplates(), runs: runs.map((r) => summary(r)), cleanup: cleanup.state });
        }
        if (req.method === "GET" && url.pathname.startsWith("/api/runs/")) {
            return json(res, 200, findRun(url.pathname.split("/")[3]));
        }
        if (req.method === "GET" && url.pathname === "/events") {
            res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
            res.write(": connected\n\n");
            clients.add(res);
            const ping = setInterval(() => res.write(": ping\n\n"), 20000);
            req.on("close", () => {
                clearInterval(ping);
                clients.delete(res);
            });
            return;
        }
        if (req.method === "POST") {
            // Simple CSRF guard: only accept JSON posts (forces a CORS preflight from foreign origins).
            if (!String(req.headers["content-type"] || "").includes("application/json")) return json(res, 415, { error: "JSON only" });
            const body = await readBody(req);
            if (url.pathname === "/api/launch") return json(res, 200, summary(startRun(body)));
            if (url.pathname === "/api/cancel") return json(res, 200, cancelRun(body.id));
            if (url.pathname === "/api/open-session") {
                const run = findRun(body.id);
                await askAgent(sessionPrompt(run, body.kind || "repo", body.target));
                return json(res, 200, { sent: true });
            }
            if (url.pathname === "/api/open-vscode") return json(res, 200, openInVSCode(findRun(body.id)));
            if (url.pathname === "/api/open-answer-key") return json(res, 200, openAnswerKey(findRun(body.id)));
            if (url.pathname === "/api/cleanup/preview") return json(res, 200, await cleanup.preview(body));
            if (url.pathname === "/api/cleanup/delete") return json(res, 200, await cleanup.remove(body));
            if (url.pathname === "/api/cleanup/reset") return json(res, 200, cleanup.reset());
            if (url.pathname === "/api/clear") {
                runs = runs.filter((r) => r.status === "running");
                persist();
                broadcast("reset", {});
                return json(res, 200, { ok: true });
            }
        }
        json(res, 404, { error: "Not found" });
    } catch (e) {
        json(res, e instanceof CanvasError ? 400 : 500, { error: e.message, code: e.code });
    }
}

function ensureServer() {
    if (!serverPromise) {
        serverPromise = new Promise((resolve) => {
            const server = createServer((req, res) => void handle(req, res));
            server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}/`));
        });
    }
    return serverPromise;
}

// ---------- canvas ----------

const templateKeys = (() => {
    try {
        return loadTemplates().map((t) => t.key);
    } catch {
        return undefined;
    }
})();

const runIdInput = { type: "object", properties: { runId: { type: "string", description: "Run id; defaults to the latest run." } } };

const session = await joinSession({
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
                    handler: async () => loadTemplates(),
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
                    handler: async (ctx) => summary(startRun(ctx.input || {})),
                },
                {
                    name: "get_run",
                    description: "Get status, links, and full log of a run (latest by default).",
                    inputSchema: runIdInput,
                    handler: async (ctx) => findRun(ctx.input?.runId),
                },
                {
                    name: "list_runs",
                    description: "List recent demo runs with their status and links.",
                    handler: async () => runs.map((r) => summary(r)).map(({ logTail, ...r }) => r),
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
                    handler: async (ctx) => cleanup.preview(ctx.input || {}),
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
                    handler: async (ctx) => cleanup.remove(ctx.input || {}),
                },
                {
                    name: "cancel",
                    description: "Stop an in-progress demo run (latest by default).",
                    inputSchema: runIdInput,
                    handler: async (ctx) => cancelRun(findRun(ctx.input?.runId).id),
                },
            ],
            open: async (ctx) => {
                const base = await ensureServer();
                const t = ctx.input?.template;
                return { title: "Demo Launcher", url: t ? `${base}?template=${encodeURIComponent(t)}` : base };
            },
        }),
    ],
});
