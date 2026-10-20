// Demo Launcher core: everything that doesn't depend on the host. It loads templates from
// config.json, runs create-repo in the background, parses its output, keeps run history,
// and exposes a small JSON API used by ui.html. Hosts (the Copilot app canvas in
// extension.mjs, the VS Code extension in vscode/) supply a `host` adapter for the rest.
//
// host = {
//   name: "app" | "vscode",
//   features: { appSessions: boolean, seedRun: "ensemble" | "chat" | null },
//   log(message, level),               // "info" | "warning"
//   sendPrompt?(prompt),               // ask the host's agent to do something (app)
//   runSeedPrompt?(run, prompt),       // run a seed prompt in the demo repo (VS Code)
//   openFolder?(path), openFile?(path), copy?(text),
// }

import { createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, existsSync, mkdirSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { createCleanup } from "./cleanup.mjs";
import { LauncherError } from "./errors.mjs";

export { LauncherError };

const EXT_DIR = dirname(fileURLToPath(import.meta.url));
export const DEFAULT_REPO_ROOT = join(EXT_DIR, "..", "..", "..");
export const UI_FILE = join(EXT_DIR, "ui.html");
const MAX_RUNS = 30;
const MAX_LOG_CHARS = 200_000;

export function createLauncher({ repoRoot = DEFAULT_REPO_ROOT, storeFile, host }) {
    const CONFIG_FILE = join(repoRoot, "config.json");
    const log = (message, level = "info") => host.log?.(message, level);

    // ---------- config ----------

    function loadTemplates() {
        const config = JSON.parse(readFileSync(CONFIG_FILE, "utf8"));
        return (config.repos || []).map((r) => ({
            key: r.key,
            displayName: r.display_name || r.key,
            description: r.description_short || "",
            hint: r.workflow_hint || "",
            workflow: r.workflow,
            template: r.template ? `${r.template_org || config.org}/${r.template}` : null,
            owner: r.owner === "org" ? config.org : r.owner || null,
            requiresClone: r.workflow === "branch_and_codespace",
            answerKey: answerKeyPath(r.key),
            seedPrompt: readSeedPrompt(r.seed_prompt_file),
        }));
    }

    // Optional "seed_prompt_file" (e.g. resources/ensemble-blank/seed-prompt.txt): the prompt the
    // presenter runs in the new repo. The panel shows it with Copy and a host-specific Run button.
    function readSeedPrompt(file) {
        if (!file) return null;
        const path = resolve(repoRoot, String(file));
        if (!path.startsWith(resolve(repoRoot) + sep) || !existsSync(path)) return null;
        return readFileSync(path, "utf8").trim() || null;
    }

    function seedPromptFor(run) {
        const prompt = loadTemplates().find((t) => t.key === run.template)?.seedPrompt;
        if (!prompt) throw new LauncherError("no_seed_prompt", "This demo has no seed prompt.");
        return prompt;
    }

    // Presenter-only notes (e.g. resources/octocart/ANSWER_KEY.md). They stay in this repo
    // and are never copied into demo repos, so the panel opens them from here.
    function answerKeyPath(key) {
        const file = join(repoRoot, "resources", String(key), "ANSWER_KEY.md");
        return existsSync(file) ? file : null;
    }

    // Hosts may inject their own GH_TOKEN (without scopes like `codespace` or `delete_repo`),
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
            ? { cmd: "powershell.exe", args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(repoRoot, "create-repo.ps1"), ...args.win] }
            : { cmd: "bash", args: [join(repoRoot, "create-repo.sh"), ...args.sh] };
    }

    // ---------- run store (durable across reloads) ----------

    let runs = [];
    try {
        runs = JSON.parse(readFileSync(storeFile, "utf8"));
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
                mkdirSync(dirname(storeFile), { recursive: true });
                writeFileSync(storeFile, JSON.stringify(runs.slice(0, MAX_RUNS), null, 2));
            } catch {
                // best effort
            }
        }, 250);
    }

    const processes = new Map(); // runId -> ChildProcess
    const listeners = new Set(); // (event, data) => void

    function summary(run, { withLog = false } = {}) {
        const { log: fullLog, ...rest } = run;
        return withLog ? run : { ...rest, logTail: fullLog.slice(-4000) };
    }

    function broadcast(event, data) {
        for (const fn of listeners) fn(event, data);
    }

    function subscribe(fn) {
        listeners.add(fn);
        return () => listeners.delete(fn);
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
        if ((m = line.match(/Copilot Code Review not requested on PR #(\d+)/))) {
            const pr = r.prs.find((p) => p.number === Number(m[1]));
            if (pr) pr.copilotReview = "live";
        }
        if ((m = line.match(/Could not request Copilot Code Review on PR #(\d+)/))) {
            const pr = r.prs.find((p) => p.number === Number(m[1]));
            if (pr) pr.copilotReview = "failed";
        }
        if ((m = line.match(/Pull requests: (https:\/\/\S+)/))) r.pullsUrl = m[1];
        if ((m = line.match(/Code scanning alerts: (https:\/\/\S+)/))) r.alertsUrl = m[1];
        if ((m = line.match(/Alert #(\d+) assigned to Copilot/))) r.copilotAlert = Number(m[1]);
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

    function startRun({ template, owner, noClone = false, openBrowser = false } = {}) {
        const tpl = loadTemplates().find((t) => t.key === template);
        if (!tpl) throw new LauncherError("unknown_template", `Unknown template '${template}'.`);
        if (noClone && tpl.requiresClone) throw new LauncherError("invalid_options", `${tpl.displayName} needs a local clone.`);

        const isWin = process.platform === "win32";
        const outDir = mkdtempSync(join(tmpdir(), "demo-launcher-"));
        const outFile = join(outDir, "outputs.txt");
        const args = isWin
            ? ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(repoRoot, "create-repo.ps1"), "-Template", template]
            : [join(repoRoot, "create-repo.sh"), "--template", template];
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
            result: { repo: null, repoUrl: null, owner: null, clonePath: null, pagesUrl: null, topPrUrl: null, pullsUrl: null, alertsUrl: null, copilotAlert: null, prs: [], issues: [], codespace: false, answerKey: tpl.answerKey },
            log: "",
        };
        runs.unshift(run);
        runs = runs.slice(0, MAX_RUNS);

        const env = scriptEnv({ GITHUB_OUTPUT: outFile });
        if (!openBrowser) env.DEMO_NO_BROWSER = "1";
        else delete env.DEMO_NO_BROWSER;

        const child = spawn(cmd, args, { cwd: repoRoot, env, stdio: ["ignore", "pipe", "pipe"] });
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
            if (outputs.alerts_url) run.result.alertsUrl = outputs.alerts_url;
            rmSync(outDir, { recursive: true, force: true });
            run.exitCode = code;
            run.status = run.cancelled ? "cancelled" : code === 0 ? "succeeded" : "failed";
            run.finishedAt = new Date().toISOString();
            delete run._pendingPrTitle;
            broadcast("run", summary(run));
            persist();
            log(
                run.status === "succeeded"
                    ? `Demo ready: ${run.templateName} → ${run.result.repoUrl}`
                    : `Demo ${run.status}: ${run.templateName} (exit ${code ?? "?"})`,
                run.status === "succeeded" ? "info" : "warning",
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
        if (!child || !run) throw new LauncherError("not_running", "That run is not in progress.");
        run.cancelled = true;
        child.kill("SIGTERM");
        return summary(run);
    }

    function findRun(id) {
        const run = id ? runs.find((r) => r.id === id) : runs[0];
        if (!run) throw new LauncherError("not_found", id ? `No run '${id}'.` : "No runs yet.");
        return run;
    }

    function listRuns() {
        return runs.map((r) => summary(r)).map(({ logTail, ...r }) => r);
    }

    function clearRuns() {
        runs = runs.filter((r) => r.status === "running");
        persist();
        broadcast("reset", {});
    }

    // ---------- cleanup ----------

    const cleanup = createCleanup({
        repoRoot,
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
        log,
    });

    // ---------- follow-ups ----------

    function readyRun(id) {
        const run = findRun(id);
        if (run.status !== "succeeded" || run.result.deleted) throw new LauncherError("not_ready", "That demo repo is not ready.");
        return run;
    }

    // Prompts for the Copilot app's agent (create_project / open_*_session / create_session).
    function sessionPrompt(run, kind, target) {
        const r = run.result;
        if (!r.repo) throw new LauncherError("no_repo", "This run did not create a repository.");
        const where = r.clonePath
            ? `It is cloned locally at ${r.clonePath} (use that path for create_project).`
            : `It is not cloned locally; create the project from the GitHub repo ${r.repo}.`;
        if (kind === "pr") {
            return `[Demo Launcher] Open a Copilot app session for pull request #${target} in ${r.repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_pr_session (repo_full_name "${r.repo}", pr_number ${target}). Don't start any work in it (omit kickoff), then navigate me to it.`;
        }
        if (kind === "issue") {
            return `[Demo Launcher] Open a Copilot app session for issue #${target} in ${r.repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_issue_session (repo_full_name "${r.repo}", issue_number ${target}). Don't start any work in it (omit kickoff), then navigate me to it.`;
        }
        if (kind === "ensemble") {
            const kickoff = { prompt: seedPromptFor(run), mode: "autopilot", model: "auto", auto_tier: "hydrafusion" };
            return `[Demo Launcher] Run the ${run.templateName} seed prompt with Ensemble in ${r.repo}. ${where} Add it as a project in this app (create_project) if it isn't one already, then call create_session with that project_id, detached: true, and exactly this kickoff object (don't change the prompt text): ${JSON.stringify(kickoff)}. Then navigate me to that session. Don't do any of the work yourself.`;
        }
        return `[Demo Launcher] I just created the demo repo ${r.repo} (${run.templateName}). ${where} Add it as a project in this app (create_project) if it isn't one already, create a new idle session in it (create_session with that project_id, no kickoff, detached: true), then navigate me to that session.`;
    }

    async function openSession(id, kind = "repo", target) {
        const run = findRun(id);
        if (!host.sendPrompt) throw new LauncherError("unsupported", "Opening Copilot app sessions isn't available here.");
        await host.sendPrompt(sessionPrompt(run, kind, target));
        return { sent: true };
    }

    // Runs the demo's seed prompt the host's way: an Ensemble autopilot session in the Copilot
    // app, or Copilot Chat agent mode in a VS Code window for the clone.
    async function runSeed(id, { requireSuccess = false } = {}) {
        const run = requireSuccess ? readyRun(id) : findRun(id);
        if (!run.result.repo || run.result.deleted) throw new LauncherError("not_ready", "That demo repo is not ready.");
        const prompt = seedPromptFor(run);
        if (host.runSeedPrompt) return { ...(await host.runSeedPrompt(run, prompt)), seedPrompt: prompt };
        if (host.sendPrompt) {
            await host.sendPrompt(sessionPrompt(run, "ensemble"));
            return { sent: true, seedPrompt: prompt };
        }
        throw new LauncherError("unsupported", "Running seed prompts isn't available here.");
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

    function detached(cmd, args, opts = {}) {
        const child = spawn(cmd, args, { detached: true, stdio: "ignore", ...opts });
        child.on("error", () => {});
        child.unref();
    }

    async function openInVSCode(run) {
        const r = run.result;
        if (!r.clonePath || !existsSync(r.clonePath)) throw new LauncherError("no_clone", "No local clone for this demo.");
        if (host.openFolder) {
            await host.openFolder(r.clonePath);
            return { opened: r.clonePath };
        }
        const code = which("code");
        if (code) detached(code, [r.clonePath], { shell: process.platform === "win32" });
        else if (process.platform === "darwin") detached("open", ["-a", "Visual Studio Code", r.clonePath]);
        else throw new LauncherError("no_vscode", "Could not find the 'code' command.");
        return { opened: r.clonePath };
    }

    // Fallback for when the panel's webview blocks navigator.clipboard.
    async function copyToClipboard(text) {
        if (host.copy) {
            await host.copy(text);
            return { copied: true };
        }
        const candidates = process.platform === "darwin" ? [["pbcopy", []]]
            : process.platform === "win32" ? [["clip", []]]
            : [["wl-copy", []], ["xclip", ["-selection", "clipboard"]], ["xsel", ["--clipboard", "--input"]]];
        for (const [cmd, args] of candidates) {
            // Ignore stdout/stderr: xclip forks a clipboard owner that keeps them open, which would block until the timeout.
            const res = spawnSync(cmd, args, { input: text, stdio: ["pipe", "ignore", "ignore"], timeout: 5000, shell: process.platform === "win32" });
            if (res.status === 0) return { copied: true };
        }
        throw new LauncherError("no_clipboard", "Could not copy to the clipboard; select the prompt text and copy it by hand.");
    }

    async function openAnswerKey(run) {
        const file = answerKeyPath(run.template);
        if (!file) throw new LauncherError("no_answer_key", "This demo has no presenter answer key.");
        if (host.openFile) {
            await host.openFile(file);
            return { opened: file };
        }
        const code = which("code");
        if (code) detached(code, [file], { shell: process.platform === "win32" });
        else if (process.platform === "darwin") detached("open", ["-t", file]);
        else if (process.platform === "win32") detached("notepad.exe", [file]);
        else detached("xdg-open", [file]);
        return { opened: file };
    }

    // ---------- JSON API (shared by the loopback server and the VS Code webview bridge) ----------

    function state() {
        return {
            host: { name: host.name, ...host.features },
            templates: loadTemplates(),
            runs: runs.map((r) => summary(r)),
            cleanup: cleanup.state,
        };
    }

    async function api(method, pathname, body = {}) {
        if (method === "GET") {
            if (pathname === "/api/state") return state();
            if (pathname.startsWith("/api/runs/")) return findRun(pathname.split("/")[3]);
        }
        if (method === "POST") {
            switch (pathname) {
                case "/api/launch": return summary(startRun(body));
                case "/api/cancel": return cancelRun(body.id);
                case "/api/open-session":
                    return body.kind === "ensemble" ? runSeed(body.id) : openSession(body.id, body.kind || "repo", body.target);
                case "/api/run-seed": return runSeed(body.id);
                case "/api/copy-seed": return copyToClipboard(seedPromptFor(findRun(body.id)));
                case "/api/open-vscode": return openInVSCode(findRun(body.id));
                case "/api/open-answer-key": return openAnswerKey(findRun(body.id));
                case "/api/cleanup/preview": return cleanup.preview(body);
                case "/api/cleanup/delete": return cleanup.remove(body);
                case "/api/cleanup/reset": return cleanup.reset();
                case "/api/clear":
                    clearRuns();
                    return { ok: true };
            }
        }
        throw new LauncherError("unknown_route", "Not found");
    }

    // ---------- loopback HTTP server (Copilot app canvas, or any browser) ----------

    let serverPromise = null;

    function readBody(req) {
        return new Promise((done, reject) => {
            let data = "";
            req.on("data", (c) => {
                data += c;
                if (data.length > 1e5) req.destroy();
            });
            req.on("end", () => {
                try {
                    done(data ? JSON.parse(data) : {});
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
            if (req.method === "GET" && url.pathname === "/events") {
                res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
                res.write(": connected\n\n");
                const unsubscribe = subscribe((event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`));
                const ping = setInterval(() => res.write(": ping\n\n"), 20000);
                req.on("close", () => {
                    clearInterval(ping);
                    unsubscribe();
                });
                return;
            }
            let body = {};
            if (req.method === "POST") {
                // Simple CSRF guard: only accept JSON posts (forces a CORS preflight from foreign origins).
                if (!String(req.headers["content-type"] || "").includes("application/json")) return json(res, 415, { error: "JSON only" });
                body = await readBody(req);
            }
            json(res, 200, await api(req.method, url.pathname, body));
        } catch (e) {
            const status = e instanceof LauncherError ? (e.code === "unknown_route" ? 404 : 400) : 500;
            json(res, status, { error: e.message, code: e.code });
        }
    }

    function ensureServer() {
        if (!serverPromise) {
            serverPromise = new Promise((done) => {
                const server = createServer((req, res) => void handle(req, res));
                server.listen(0, "127.0.0.1", () => done(`http://127.0.0.1:${server.address().port}/`));
            });
        }
        return serverPromise;
    }

    return {
        repoRoot,
        loadTemplates,
        startRun: (input) => summary(startRun(input)),
        cancelRun: (id) => cancelRun(findRun(id).id),
        getRun: (id) => findRun(id),
        listRuns,
        runSeed,
        cleanupPreview: (input) => cleanup.preview(input || {}),
        cleanupDelete: (input) => cleanup.remove(input || {}),
        api,
        subscribe,
        ensureServer,
    };
}
