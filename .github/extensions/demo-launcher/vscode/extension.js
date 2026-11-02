// Demo Launcher for VS Code. A thin host around ../core.mjs (shared with the Copilot app
// canvas): the panel is ../ui.html in a webview, with fetch/EventSource bridged over
// postMessage, and the canvas actions are exposed as Copilot agent-mode tools.

const vscode = require("vscode");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const crypto = require("node:crypto");
const { pathToFileURL } = require("node:url");

const CORE_REL = path.join(".github", "extensions", "demo-launcher", "core.mjs");
const PENDING_MAX_AGE_MS = 5 * 60 * 1000;

let context;
let launcherPromise = null;
let panel = null;
let output;

function expandHome(p) {
    return p && p.startsWith("~") ? path.join(os.homedir(), p.slice(1)) : p;
}

// The setting wins, then an open workspace that is repo-setup-scripts (so a branch you're
// working on uses its own copy), then the checkout the installer recorded, then the
// checkout this file lives in (when run with --extensionDevelopmentPath).
function findRepoRoot() {
    const isRepo = (p) => p && fs.existsSync(path.join(p, "config.json")) && fs.existsSync(path.join(p, CORE_REL));
    const candidates = [expandHome(vscode.workspace.getConfiguration("demoLauncher").get("repoPath"))];
    for (const f of vscode.workspace.workspaceFolders || []) candidates.push(f.uri.fsPath);
    try {
        candidates.push(JSON.parse(fs.readFileSync(path.join(context.extensionPath, "repo-path.json"), "utf8")).repoPath);
    } catch {
        // not installed by install.sh
    }
    candidates.push(path.resolve(__dirname, "..", "..", "..", ".."));
    return candidates.find(isRepo) || null;
}

function storageDir() {
    const dir = context.globalStorageUri.fsPath;
    fs.mkdirSync(dir, { recursive: true });
    return dir;
}

// Run history lives in workspace storage: each VS Code window runs its own launcher, and VS Code
// opens a workspace in only one window, so no two launchers share a history file. A window with
// no folder open keeps a scratch history that's gone when the window closes.
function historyFile() {
    let dir = context.storageUri?.fsPath;
    if (dir) fs.mkdirSync(dir, { recursive: true });
    else {
        const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "demo-launcher-"));
        context.subscriptions.push({ dispose: () => fs.rmSync(scratch, { recursive: true, force: true }) });
        dir = scratch;
    }
    return path.join(dir, "runs.json");
}

function getLauncher() {
    if (!launcherPromise) {
        launcherPromise = (async () => {
            const repoRoot = findRepoRoot();
            if (!repoRoot) {
                throw new Error("Demo Launcher can't find your repo-setup-scripts checkout. Open it as a workspace folder, re-run vscode/install.sh, or set the demoLauncher.repoPath setting.");
            }
            const core = await import(pathToFileURL(path.join(repoRoot, CORE_REL)).href);
            output.appendLine(`Using ${repoRoot}`);
            return { core, launcher: core.createLauncher({ repoRoot, storeFile: historyFile(), host }) };
        })();
        launcherPromise.catch(() => (launcherPromise = null));
    }
    return launcherPromise;
}

// ---------- host adapter for core.mjs ----------

const host = {
    name: "vscode",
    features: { appSessions: false, seedRun: "chat" },
    log(message, level) {
        output.appendLine(message);
        if (/^Demo (ready|succeeded|failed|cancelled|interrupted)/.test(message)) {
            (level === "warning" ? vscode.window.showWarningMessage : vscode.window.showInformationMessage)(message);
        }
    },
    async openFolder(folder) {
        await vscode.commands.executeCommand("vscode.openFolder", vscode.Uri.file(folder), { forceNewWindow: true });
    },
    async openFile(file) {
        const uri = vscode.Uri.file(file);
        try {
            await vscode.commands.executeCommand("markdown.showPreview", uri);
        } catch {
            await vscode.window.showTextDocument(uri, { preview: true });
        }
    },
    async copy(text) {
        await vscode.env.clipboard.writeText(text);
    },
    // Hand the prompt to whichever window has the clone open: this one, an existing one
    // (it watches the pending file), or the new window we open (it checks on startup).
    async runSeedPrompt(run, prompt) {
        const folder = run.result.clonePath;
        if (!folder || !fs.existsSync(folder)) throw new Error("This demo has no local clone to open.");
        if (isOpenHere(folder)) {
            await runInChat(prompt);
            return { ranHere: true };
        }
        // One file per request, so a second handoff can't overwrite one that's still unclaimed.
        const file = path.join(storageDir(), `${PENDING_PREFIX}${crypto.randomUUID()}.json`);
        fs.writeFileSync(`${file}.tmp`, JSON.stringify({ folder, prompt, createdAt: Date.now() }));
        fs.renameSync(`${file}.tmp`, file);
        await host.openFolder(folder);
        return { opened: folder };
    },
};

// ---------- seed prompts in Copilot Chat ----------

const PENDING_PREFIX = "pending-prompt-";

function isPendingFile(name) {
    return Boolean(name) && name.startsWith(PENDING_PREFIX) && name.endsWith(".json");
}

function samePath(a, b) {
    try {
        return fs.realpathSync(a) === fs.realpathSync(b);
    } catch {
        return path.resolve(a) === path.resolve(b);
    }
}

function isOpenHere(folder) {
    return (vscode.workspace.workspaceFolders || []).some((f) => samePath(f.uri.fsPath, folder));
}

async function runInChat(prompt) {
    await vscode.extensions.getExtension("GitHub.copilot-chat")?.activate();
    await vscode.commands.executeCommand("workbench.action.chat.open", { query: prompt, mode: "agent" });
}

// Claim pending prompts meant for this window. Renaming is atomic, so only one window wins each.
async function checkPendingPrompts() {
    let names;
    try {
        names = fs.readdirSync(storageDir()).filter(isPendingFile);
    } catch {
        return;
    }
    for (const name of names) await checkPendingPrompt(path.join(storageDir(), name));
}

async function checkPendingPrompt(file) {
    let pending;
    try {
        pending = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
        return;
    }
    if (!(Date.now() - pending.createdAt <= PENDING_MAX_AGE_MS)) return void fs.rmSync(file, { force: true });
    if (!isOpenHere(pending.folder)) return;
    const claimed = `${file}.${process.pid}`;
    try {
        fs.renameSync(file, claimed);
    } catch {
        return;
    }
    fs.rmSync(claimed, { force: true });
    try {
        await runInChat(pending.prompt);
    } catch (e) {
        await vscode.env.clipboard.writeText(pending.prompt);
        vscode.window.showWarningMessage(`Couldn't start Copilot Chat (${e.message}). The seed prompt is on your clipboard.`);
    }
}

function watchPendingPrompts() {
    if (!vscode.workspace.workspaceFolders?.length) return;
    void checkPendingPrompts();
    try {
        const watcher = fs.watch(storageDir(), (_event, name) => {
            if (isPendingFile(name)) void checkPendingPrompts();
        });
        context.subscriptions.push({ dispose: () => watcher.close() });
    } catch {
        // fs.watch unsupported; startup check still covers new windows
    }
}

// ---------- panel ----------

const THEME_CSS = `
:root {
  --background-color-default: var(--vscode-editor-background);
  --background-color-muted: var(--vscode-textCodeBlock-background, rgba(127,127,127,.1));
  --text-color-default: var(--vscode-foreground);
  --text-color-muted: var(--vscode-descriptionForeground);
  --border-color-default: var(--vscode-widget-border, var(--vscode-panel-border, rgba(127,127,127,.35)));
  --true-color-blue: var(--vscode-textLink-foreground);
  --true-color-green: var(--vscode-testing-iconPassed, #1a7f37);
  --true-color-red: var(--vscode-errorForeground);
  --true-color-orange: var(--vscode-editorWarning-foreground);
  --font-sans: var(--vscode-font-family);
  --font-mono: var(--vscode-editor-font-family);
}
button.primary { background: var(--vscode-button-background); border-color: var(--vscode-button-background); color: var(--vscode-button-foreground); }`;

// Makes ui.html's fetch() and EventSource talk to the extension over postMessage.
const BRIDGE_JS = `
(() => {
  const vscode = acquireVsCodeApi();
  const pending = new Map();
  const sources = new Set();
  let seq = 0;
  window.addEventListener("message", (e) => {
    const m = e.data || {};
    if (m.type === "response") { pending.get(m.id)?.(m); pending.delete(m.id); }
    if (m.type === "event") for (const s of sources) s.dispatch(m.event, m.data);
    if (m.type === "select" && typeof renderTemplates === "function") { selected = m.template; renderTemplates(); }
  });
  window.fetch = (url, opts = {}) => new Promise((resolve) => {
    const id = ++seq;
    pending.set(id, resolve);
    vscode.postMessage({ type: "request", id, method: opts.method || "GET", path: String(url), body: opts.body ? JSON.parse(opts.body) : {} });
  }).then((m) => ({ ok: m.status < 400, status: m.status, statusText: m.body?.error || "", json: async () => m.body }));
  window.EventSource = class {
    constructor() { this.listeners = {}; this.onerror = null; sources.add(this); }
    addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
    close() { sources.delete(this); }
    dispatch(type, data) { for (const fn of this.listeners[type] || []) fn({ data: JSON.stringify(data) }); }
  };
})();`;

function renderHtml(core, webview, template) {
    const nonce = crypto.randomBytes(16).toString("base64");
    const csp = `default-src 'none'; style-src 'unsafe-inline' ${webview.cspSource}; img-src ${webview.cspSource} https: data:; script-src 'nonce-${nonce}';`;
    const head = `<meta http-equiv="Content-Security-Policy" content="${csp}">
<script nonce="${nonce}">window.DEMO_LAUNCHER = ${JSON.stringify({ template: template || null }).replace(/</g, "\\u003c")};${BRIDGE_JS}</script>`;
    return fs.readFileSync(core.UI_FILE, "utf8")
        .replace("<head>", `<head>\n${head}`)
        .replace("</head>", `<style>${THEME_CSS}</style>\n</head>`) // after ui.html's styles, so these win
        .replace(/<script>/g, `<script nonce="${nonce}">`);
}

async function openPanel(template, { preserveFocus = false } = {}) {
    const { core, launcher } = await getLauncher();
    if (panel) {
        panel.reveal(undefined, preserveFocus);
        if (template) panel.webview.postMessage({ type: "select", template });
        return;
    }
    panel = vscode.window.createWebviewPanel("demoLauncher", "Demo Launcher", { viewColumn: vscode.ViewColumn.Active, preserveFocus }, {
        enableScripts: true,
        retainContextWhenHidden: true,
        localResourceRoots: [],
    });
    const webview = panel.webview;
    const unsubscribe = launcher.subscribe((event, data) => void webview.postMessage({ type: "event", event, data }));
    webview.onDidReceiveMessage(async (m) => {
        if (m?.type !== "request") return;
        let status = 200;
        let body;
        try {
            body = await launcher.api(m.method, new URL(m.path, "http://localhost").pathname, m.body);
        } catch (e) {
            status = e instanceof core.LauncherError ? (e.code === "unknown_route" ? 404 : 400) : 500;
            body = { error: e.message, code: e.code };
        }
        void webview.postMessage({ type: "response", id: m.id, status, body });
    });
    panel.onDidDispose(() => {
        unsubscribe();
        panel = null;
    });
    webview.html = renderHtml(core, webview, template);
}

// ---------- agent-mode tools ----------

function result(value) {
    return new vscode.LanguageModelToolResult([new vscode.LanguageModelTextPart(JSON.stringify(value, null, 2))]);
}

function trimLog(run) {
    return run.log && run.log.length > 20000 ? { ...run, log: `…${run.log.slice(-20000)}` } : run;
}

const tools = {
    demoLauncher_open: {
        invoke: async ({ template }) => {
            await openPanel(template);
            return { opened: true };
        },
    },
    demoLauncher_listTemplates: { invoke: async (_, { launcher }) => launcher.loadTemplates() },
    demoLauncher_launch: {
        message: ({ template }) => `Creating the ${template} demo`,
        invoke: async (input, { launcher }) => {
            const run = launcher.startRun(input);
            await openPanel(undefined, { preserveFocus: true });
            return run;
        },
    },
    demoLauncher_getRun: { invoke: async ({ runId }, { launcher }) => trimLog(launcher.getRun(runId)) },
    demoLauncher_listRuns: { invoke: async (_, { launcher }) => launcher.listRuns() },
    demoLauncher_cancel: { invoke: async ({ runId }, { launcher }) => launcher.cancelRun(runId) },
    demoLauncher_runSeedPrompt: {
        message: () => "Opening the demo and running its seed prompt in Copilot Chat",
        invoke: async ({ runId }, { launcher }) => launcher.runSeed(runId, { requireSuccess: true }),
    },
    demoLauncher_cleanupPreview: {
        message: () => "Finding demo repos to clean up",
        invoke: async (input, { launcher }) => {
            await openPanel(undefined, { preserveFocus: true });
            return launcher.cleanupPreview(input);
        },
    },
    demoLauncher_cleanupDelete: {
        // The tool takes an explicit repo list, so the confirmation shows exactly what this call can
        // delete. The core further limits it to repos still in the current preview.
        confirm: async ({ repos, removeClones }) => {
            const list = (repos || []).map((r) => `- \`${r}\``).join("\n") || "_(none)_";
            return {
                title: "Delete demo repos?",
                message: new vscode.MarkdownString(`This permanently deletes these repos${removeClones ? " and their local clones" : ""}:\n\n${list}`),
            };
        },
        invoke: async ({ repos, removeClones }, { launcher }) => {
            if (!Array.isArray(repos) || !repos.length) throw new Error("nothing_selected: Pass the repos to delete (owner/name) from the cleanup preview.");
            return launcher.cleanupDelete({ repos, removeClones });
        },
    },
};

function registerTools() {
    if (!vscode.lm?.registerTool) return;
    for (const [name, tool] of Object.entries(tools)) {
        context.subscriptions.push(
            vscode.lm.registerTool(name, {
                async prepareInvocation({ input }) {
                    const prep = {};
                    if (tool.message) prep.invocationMessage = tool.message(input || {});
                    if (tool.confirm) prep.confirmationMessages = await tool.confirm(input || {}, await getLauncher());
                    return prep;
                },
                async invoke({ input }) {
                    try {
                        return result(await tool.invoke(input || {}, await getLauncher()));
                    } catch (e) {
                        throw new Error(e.code ? `${e.code}: ${e.message}` : e.message);
                    }
                },
            }),
        );
    }
}

// ---------- activation ----------

function activate(ctx) {
    context = ctx;
    output = vscode.window.createOutputChannel("Demo Launcher");
    context.subscriptions.push(output);
    context.subscriptions.push(
        vscode.commands.registerCommand("demoLauncher.open", async (template) => {
            try {
                await openPanel(typeof template === "string" ? template : undefined);
            } catch (e) {
                vscode.window.showErrorMessage(e.message);
            }
        }),
    );
    registerTools();
    watchPendingPrompts();
}

function deactivate() {}

module.exports = { activate, deactivate };
