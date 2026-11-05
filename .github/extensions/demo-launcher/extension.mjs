// Demo Launcher canvas: pick a template from config.json, run create-repo in the
// background, watch the log, then jump into the new repo (app session, VS Code, GitHub).

import { createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir, homedir } from "node:os";
import { join, dirname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { joinSession, createCanvas, CanvasError } from "@github/copilot-sdk/extension";
import { createCleanup } from "./cleanup.mjs";
import { createRunStore } from "./run-store.mjs";

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
        template: r.template ? `${r.template_org || config.org}/${r.template}` : null,
        owner: r.owner === "org" ? config.org : r.owner || null,
        requiresClone: r.workflow === "branch_and_codespace",
        answerKey: answerKeyPath(r.key),
        ...readSeedPrompts(r),
    }));
}

// Prompts the presenter runs in the new repo; the canvas shows each with Copy and
// "Run with Fusion". Either one unlabeled "seed_prompt_file" (e.g. fusion-blank) or
// "seed_prompts": [{ label, file }] (e.g. fusion-routing), whose label goes in the session name.
// Labels must stay distinct after cleanLabel + labelKey (the same rule create-repo and CI
// enforce); otherwise the template gets seedPromptError and no prompts, rather than one label
// silently launching another label's prompt.
function readSeedPrompts(r) {
    if (r.seed_prompts === undefined) {
        const text = readSeedPrompt(r.seed_prompt_file);
        return { seedPrompts: text ? [{ label: null, text }] : [] };
    }
    const fail = (why) => ({ seedPrompts: [], seedPromptError: `seed_prompts in config.json ${why}.` });
    if (!Array.isArray(r.seed_prompts) || !r.seed_prompts.length) return fail("must be a non-empty list");
    const seen = new Map();
    for (const p of r.seed_prompts) {
        const key = labelKey(p?.label);
        if (!key) return fail("needs a non-empty label on every entry");
        if (seen.has(key)) return fail(`has labels that collide (${JSON.stringify(seen.get(key))} and ${JSON.stringify(p.label)})`);
        seen.set(key, p.label);
    }
    const seedPrompts = r.seed_prompts.map((p) => ({ label: cleanLabel(p.label), text: readSeedPrompt(p.file) }));
    const missing = seedPrompts.find((p) => !p.text);
    return missing ? fail(`has no readable file for ${JSON.stringify(missing.label)}`) : { seedPrompts };
}

// Control characters become spaces, outer spaces are trimmed, the label keeps its first 40 code
// points, and trailing spaces left by that cut are trimmed too (so cleaning is idempotent).
// create-repo.sh/.ps1 and CI's Validate config apply the same steps.
function cleanLabel(label) {
    if (typeof label !== "string") return null;
    const cleaned = Array.from(label.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/^ +| +$/g, "")).slice(0, 40).join("").replace(/ +$/, "");
    return cleaned || null;
}

// Lookups are case-insensitive for ASCII letters only, so every validator agrees.
function labelKey(label) {
    return cleanLabel(label)?.replace(/[A-Z]/g, (c) => c.toLowerCase()) ?? null;
}

function readSeedPrompt(file) {
    if (!file) return null;
    const path = resolve(REPO_ROOT, String(file));
    if (!path.startsWith(resolve(REPO_ROOT) + sep) || !existsSync(path)) return null;
    return readFileSync(path, "utf8").trim() || null;
}

// `which` is the prompt's index or label; defaults to the first prompt.
function seedPromptFor(run, which) {
    const tpl = loadTemplates().find((t) => t.key === run.template);
    if (tpl?.seedPromptError) throw new CanvasError("bad_seed_prompts", tpl.seedPromptError);
    const prompts = tpl?.seedPrompts || [];
    if (!prompts.length) throw new CanvasError("no_seed_prompt", "This demo has no seed prompt.");
    if (which === undefined || which === null || which === "") return prompts[0];
    const key = labelKey(String(which));
    const index = Number.isSafeInteger(which) ? which : prompts.findIndex((p) => p.label && labelKey(p.label) === key);
    const prompt = prompts[index];
    if (!prompt) throw new CanvasError("bad_seed_prompt", `This demo has no seed prompt ${JSON.stringify(String(which))}.`);
    return prompt;
}

// Presenter-only notes (e.g. resources/octocart/ANSWER_KEY.md). They stay in this repo
// and are never copied into demo repos, so the canvas opens them from here.
function answerKeyPath(key) {
    const file = join(REPO_ROOT, "resources", String(key), "ANSWER_KEY.md");
    return existsSync(file) ? file : null;
}

// ---------- tool discovery ----------

// The app can launch extensions with a minimal PATH (/usr/bin:/bin:...), so gh from Homebrew
// isn't found. Add the same locations create-repo.sh adds, plus the login shell's PATH.
const PATH_SEP = process.platform === "win32" ? ";" : ":";
const TOOL_PATH = buildToolPath();
const GH = which("gh") || "gh";

function buildToolPath() {
    const current = process.env.PATH || process.env.Path || "";
    if (process.platform === "win32") return current;
    const dirs = current.split(PATH_SEP).filter(Boolean);
    const add = (d) => d && !dirs.includes(d) && dirs.push(d);
    for (const d of ["/opt/homebrew/bin", "/usr/local/bin", join(homedir(), ".local", "bin"), join(homedir(), "bin")]) {
        if (existsSync(d)) add(d);
    }
    if (!dirs.some((d) => existsSync(join(d, "gh"))) && process.env.SHELL && existsSync(process.env.SHELL)) {
        const out = spawnSync(process.env.SHELL, ["-lic", 'printf "\\n__DEMO_PATH__%s\\n" "$PATH"'], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], timeout: 10000 });
        const login = (out.stdout || "").match(/^__DEMO_PATH__(.*)$/m)?.[1] || "";
        login.split(PATH_SEP).forEach(add);
    }
    return dirs.join(PATH_SEP);
}

function which(bin) {
    const extra = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Visual Studio Code.app/Contents/Resources/app/bin"];
    // Prefer .exe on Windows: spawning a .cmd without a shell fails.
    const names = process.platform === "win32" ? [`${bin}.exe`, `${bin}.cmd`] : [bin];
    for (const p of [...TOOL_PATH.split(PATH_SEP), ...extra]) {
        if (!p) continue;
        for (const name of names) {
            if (existsSync(join(p, name))) return join(p, name);
        }
    }
    return null;
}

// The app may inject its own GH_TOKEN (without scopes like `codespace` or `delete_repo`),
// which would override the user's `gh auth login`. Prefer the stored login, like a terminal run.
// The app also points git's github.com credential helper at its own account (via
// GIT_CONFIG_PARAMETERS), so when gh uses the stored login, make git use gh too.
// Otherwise pushes run as the app's account and fail with 403 on the booth account's repos.
function scriptEnv(extra = {}) {
    const env = { ...process.env, PATH: TOOL_PATH, NO_COLOR: "1", ...extra };
    if (process.platform === "win32") delete env.Path;
    delete env.GITHUB_ACTIONS;
    if (env.GH_TOKEN || env.GITHUB_TOKEN) {
        const stored = { ...env };
        delete stored.GH_TOKEN;
        delete stored.GITHUB_TOKEN;
        const probe = spawnSync(GH, ["auth", "token", "-h", "github.com"], { env: stored, stdio: "ignore", timeout: 10000 });
        if (probe.status === 0) return withGhGitCredentials(stored);
    }
    return env;
}

// Append (rather than replace) so other app-injected settings survive. An empty helper
// value resets the helper list, so only `gh auth git-credential` answers for github.com.
function withGhGitCredentials(env) {
    const key = "credential.https://github.com.helper";
    const params = [`${key}=`, `${key}=!${shellQuote(GH)} auth git-credential`];
    // GIT_CONFIG_PARAMETERS entries use the same single-quote escaping as sh.
    const quoted = params.map(shellQuote).join(" ");
    env.GIT_CONFIG_PARAMETERS = env.GIT_CONFIG_PARAMETERS ? `${env.GIT_CONFIG_PARAMETERS} ${quoted}` : quoted;
    return env;
}

// Git runs `!` helpers with sh (Git Bash on Windows), so single quotes keep paths with
// spaces or backslashes intact. This matches what `gh auth setup-git` writes.
function shellQuote(s) {
    return `'${s.replace(/'/g, `'\\''`)}'`;
}

function scriptCommand(args) {
    return process.platform === "win32"
        ? { cmd: "powershell.exe", args: ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(REPO_ROOT, "create-repo.ps1"), ...args.win] }
        : { cmd: "bash", args: [join(REPO_ROOT, "create-repo.sh"), ...args.sh] };
}

// ---------- run store (durable across reloads) ----------

// Renamed template keys, so runs saved before a rename keep their seed prompt and answer key.
const LEGACY_TEMPLATE_KEYS = { "ensemble-blank": "fusion-blank" };

const processes = new Map(); // runId -> ChildProcess
const clients = new Set(); // SSE responses

function normalizeRun(r) {
    const renamed = LEGACY_TEMPLATE_KEYS[r.template];
    if (!renamed) return;
    r.template = renamed;
    try {
        const tpl = loadTemplates().find((t) => t.key === renamed);
        if (tpl) r.templateName = tpl.displayName;
    } catch {
        // keep the stored name if config.json can't be read
    }
    if (r.result) r.result.answerKey = answerKeyPath(renamed);
}

// Shared with every other Demo Launcher process (one per chat, plus standalone canvases).
const store = createRunStore({
    file: STORE_FILE,
    maxRuns: MAX_RUNS,
    normalize: normalizeRun,
    isOwned: (id) => processes.has(id),
    onChange({ removed, changed }) {
        if (removed) broadcast("reset", {});
        else for (const r of changed) broadcast("run", summary(r));
    },
});
store.watch();
const allRuns = () => store.sync();

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
        result: { repo: null, repoUrl: null, owner: null, clonePath: null, pagesUrl: null, topPrUrl: null, pullsUrl: null, alertsUrl: null, copilotAlert: null, prs: [], issues: [], codespace: false, answerKey: tpl.answerKey },
        log: "",
    };
    const env = scriptEnv({ GITHUB_OUTPUT: outFile });
    if (!openBrowser) env.DEMO_NO_BROWSER = "1";
    else delete env.DEMO_NO_BROWSER;

    const child = spawn(cmd, args, { cwd: REPO_ROOT, env, stdio: ["ignore", "pipe", "pipe"] });
    processes.set(run.id, child);
    store.add(run);

    let partial = "";
    const onData = (chunk) => {
        const text = chunk.toString();
        run.log = (run.log + text).slice(-MAX_LOG_CHARS);
        partial += text;
        const lines = partial.split(/\r?\n/);
        partial = lines.pop();
        for (const l of lines) parseLine(run, l);
        broadcast("run", summary(run));
        store.touch(run);
    };
    child.stdout.on("data", onData);
    child.stderr.on("data", onData);

    const finish = (code, err) => {
        if (run.status !== "running") return;
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
        store.touch(run);
        processes.delete(run.id);
        broadcast("run", summary(run));
        chatLog(
            run.status === "succeeded"
                ? `Demo ready: ${run.templateName} → ${run.result.repoUrl}`
                : `Demo ${run.status}: ${run.templateName} (exit ${code ?? "?"})`,
            { level: run.status === "succeeded" ? "info" : "warning" },
        );
    };
    child.on("error", (e) => finish(null, e));
    child.on("close", (code) => finish(code));

    broadcast("run", summary(run));
    return run;
}

function cancelRun(id) {
    const child = processes.get(id);
    const run = allRuns().find((r) => r.id === id);
    if (!child && run?.status === "running") throw new CanvasError("not_running", "That run was started from another Demo Launcher panel or chat; cancel it there.");
    if (!child || !run) throw new CanvasError("not_running", "That run is not in progress.");
    run.cancelled = true;
    child.kill("SIGTERM");
    return summary(run);
}

function findRun(id) {
    const runs = allRuns();
    const run = id ? runs.find((r) => r.id === id) : runs[0];
    if (!run) throw new CanvasError("not_found", id ? `No run '${id}'.` : "No runs yet.");
    return run;
}

// ---------- cleanup ----------

const cleanup = createCleanup({
    repoRoot: REPO_ROOT,
    scriptEnv,
    scriptCommand,
    gh: GH,
    broadcast,
    onRepoDeleted(repo) {
        for (const r of allRuns()) {
            if (r.result.repo?.toLowerCase() === repo.toLowerCase() && !r.result.deleted) {
                r.result.deleted = true;
                store.touch(r);
                broadcast("run", summary(r));
            }
        }
    },
    log: (message, level) => chatLog(message, { level }),
});

// ---------- follow-ups ----------

const REPO_NAME_RE = /^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/;
const REPOS_ROOT = resolve(homedir(), "repos");
// eslint-disable-next-line no-control-regex
const CONTROL_CHARS = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/;

// Everything interpolated into agent prompts or app links comes from script output and
// request bodies, so validate it first and refuse rather than send anything unexpected.
function safeRunFields(run, kind, target) {
    const r = run.result;
    if (!r.repo) throw new CanvasError("no_repo", "This run did not create a repository.");
    const repo = String(r.repo);
    if (!REPO_NAME_RE.test(repo)) throw new CanvasError("bad_repo", "This run's repository name isn't a valid owner/name.");
    let clonePath = null;
    if (r.clonePath) {
        const raw = String(r.clonePath);
        const abs = resolve(raw);
        if (CONTROL_CHARS.test(raw) || !abs.startsWith(REPOS_ROOT + sep)) {
            throw new CanvasError("bad_clone_path", `This run's clone path isn't under ${REPOS_ROOT}.`);
        }
        clonePath = abs;
    }
    let number = null;
    if (kind === "pr" || kind === "issue") {
        number = Number(target);
        if (!Number.isSafeInteger(number) || number <= 0) throw new CanvasError("bad_target", `That ${kind === "pr" ? "PR" : "issue"} number isn't valid.`);
    }
    const templateName = String(run.templateName || run.template || "demo").replace(new RegExp(CONTROL_CHARS.source, "g"), " ").trim().slice(0, 100);
    return { repo, clonePath, number, templateName };
}

// Fusion tiers the presenter can pick. The app's model picker sends auto_tier "hydrafusion"
// for Standard and High, and "hydrafusion-max" for Max. Only these ids ever reach a kickoff.
const FUSION_TIERS = {
    high: { autoTier: "hydrafusion", name: "Fusion", picker: "GitHub Copilot Fusion" },
    max: { autoTier: "hydrafusion-max", name: "Fusion Max", picker: "GitHub Copilot Fusion Max" },
};

function fusionTier(tier) {
    if (tier === undefined || tier === null || tier === "") return "high";
    const key = String(tier).toLowerCase();
    if (!Object.hasOwn(FUSION_TIERS, key)) throw new CanvasError("bad_tier", `Unknown Fusion tier ${JSON.stringify(String(tier))}; use "high" or "max".`);
    return key;
}

function sessionPrompt(run, kind, target, tier) {
    const { repo, clonePath, number, templateName } = safeRunFields(run, kind, target);
    const where = clonePath
        ? `It is cloned locally at ${JSON.stringify(clonePath)} (use that path for create_project).`
        : `It is not cloned locally; create the project from the GitHub repo ${repo}.`;
    if (kind === "pr") {
        return `[Demo Launcher] Open a Copilot app session for pull request #${number} in ${repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_pr_session (repo_full_name "${repo}", pr_number ${number}). Don't start any work in it (omit kickoff), then navigate me to it.`;
    }
    if (kind === "issue") {
        return `[Demo Launcher] Open a Copilot app session for issue #${number} in ${repo}. ${where} First add it as a project in this app (create_project) if it isn't one already, then use open_issue_session (repo_full_name "${repo}", issue_number ${number}). Don't start any work in it (omit kickoff), then navigate me to it.`;
    }
    if (kind === "fusion") {
        const seed = seedPromptFor(run, target);
        const t = FUSION_TIERS[fusionTier(tier)];
        const kickoff = { prompt: seed.text, mode: "autopilot", model: "auto", auto_tier: t.autoTier };
        const which = seed.label ? `${JSON.stringify(seed.label)} seed prompt from ${JSON.stringify(templateName)}` : `${JSON.stringify(templateName)} seed prompt`;
        // High keeps the original wording; Max always gets a name so it stands out from High runs.
        const prefix = seed.label ? `[${t.name} - ${seed.label}] ` : t === FUSION_TIERS.max ? `[${t.name}] ` : null;
        const name = prefix ? ` Set the session name to ${JSON.stringify(prefix)} followed by a 2-4 word summary of the prompt, so the sessions are easy to compare.` : "";
        return `[Demo Launcher] Run the ${which} with ${t.picker} in ${repo}. ${where} Add it as a project in this app (create_project) if it isn't one already, then call create_session with that project_id, detached: true, and exactly this kickoff object (don't change the prompt text): ${JSON.stringify(kickoff)}.${name} Then navigate me to that session. Don't do any of the work yourself.`;
    }
    return `[Demo Launcher] I just created the demo repo ${repo} (${JSON.stringify(templateName)}). ${where} Add it as a project in this app (create_project) if it isn't one already, create a new idle session in it (create_session with that project_id, no kickoff, detached: true), then navigate me to that session.`;
}

// Opened from the app-wide canvas picker (no chat), the canvas is hosted by a hidden
// control session that the app runs under ~/.copilot/app-extension-control/ with
// `--no-auto-login`. That session can't run agent turns: session.send() starts one, it
// fails ("Session was not created with authentication info"), and the app then tears
// down the whole canvas activation ("Runtime canvas control session failed").
let standaloneCache;
function isStandalone() {
    if (standaloneCache !== undefined) return standaloneCache;
    const mark = `${sep}app-extension-control${sep}`;
    if ([session?.workspacePath, process.env.COPILOT_HOME].some((p) => p && p.includes(mark))) return (standaloneCache = true);
    if (process.platform !== "win32") {
        const res = spawnSync("ps", ["-o", "args=", "-p", String(process.ppid)], { encoding: "utf8", timeout: 3000 });
        if (res.status === 0 && /(^|\s)--no-auto-login(\s|$)/.test(res.stdout)) return (standaloneCache = true);
    }
    return (standaloneCache = false);
}

// Logs only reach a chat; in standalone mode there is none, so don't touch the control session.
function chatLog(message, options) {
    if (session && !isStandalone()) session.log(message, options);
}

// App deep links (verified routes: repository clone/add prompt, PR detail, issue detail).
// Built only from a validated owner/name and an integer, so the URL can't carry arguments.
function appDeepLink(run, kind, target) {
    const repo = String(run.result.repo || "");
    if (!REPO_NAME_RE.test(repo)) throw new CanvasError("bad_repo", "This run has no valid repository name.");
    const base = `ghapp://github.com/${repo}`;
    const n = Number(target);
    if ((kind === "pr" || kind === "issue") && Number.isSafeInteger(n) && n > 0) return `${base}/${kind === "pr" ? "pull" : "issues"}/${n}`;
    return base;
}

function openExternalUrl(url) {
    if (!/^ghapp:\/\/github\.com\/[A-Za-z0-9._\/-]+$/.test(url)) return false;
    // No shell: on Windows, hand the URL to the protocol handler directly instead of `cmd /c start`.
    const [cmd, args] = process.platform === "darwin" ? ["open", [url]]
        : process.platform === "win32" ? ["rundll32.exe", ["url.dll,FileProtocolHandler", url]]
        : ["xdg-open", [url]];
    const res = spawnSync(cmd, args, { stdio: "ignore", timeout: 10000, shell: false });
    return res.status === 0;
}

const APP_BUNDLE_ID = "com.github.githubapp";

// The app registers folders as a document type. Opening one (like `open -a` or a Dock drop)
// adds it as a project if needed — no confirmation — and shows its new-session composer.
function openFolderInApp(path) {
    if (process.platform !== "darwin" || !path || !existsSync(path)) return false;
    return spawnSync("open", ["-b", APP_BUNDLE_ID, path], { stdio: "ignore", timeout: 10000 }).status === 0;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// In a chat: ask the agent (it can add the project, create the session, and navigate).
// Standalone: no agent is available, so open the local clone in the app (adds the project and
// lands on its new-session composer), then the PR/issue if one was picked. Without a clone,
// fall back to the GitHub deep link, which asks the user to confirm adding the repo.
async function openSession(run, kind, target, tier) {
    const prompt = sessionPrompt(run, kind, target, tier);
    if (!session) throw new CanvasError("no_session", "Extension is not connected to a session.");
    if (!isStandalone()) {
        await session.send({ prompt });
        return { sent: true };
    }
    const { repo, clonePath, number } = safeRunFields(run, kind, target);
    const isItem = kind === "pr" || kind === "issue";
    const itemLabel = isItem ? `${kind === "pr" ? "PR" : "issue"} #${number}` : null;
    const itemLink = isItem ? appDeepLink(run, kind, number) : null;
    const itemUrl = isItem ? `https://github.com/${repo}/${kind === "pr" ? "pull" : "issues"}/${number}` : null;
    const repoLink = appDeepLink(run, "repo");

    const folderOpened = openFolderInApp(clonePath);
    // Without a clone the repo link asks the user to Allow adding the project. Opening the
    // item link right away would replace that prompt, so the first click opens the repo and
    // a second click (after Allow) opens the PR/issue.
    const awaitingAllow = !folderOpened && isItem && !run._repoLinkOpened;
    let repoLinkOpened = false;
    let linkOpened = false;
    if (!folderOpened && (!isItem || awaitingAllow)) {
        repoLinkOpened = openExternalUrl(repoLink);
        if (repoLinkOpened) {
            run._repoLinkOpened = true;
            store.touch(run);
        }
    }
    if (isItem && !awaitingAllow) {
        if (folderOpened) await sleep(2500);
        linkOpened = openExternalUrl(itemLink);
    }

    let copied = false;
    if (kind === "fusion") {
        try {
            copied = copyToClipboard(seedPromptFor(run, target).text).copied;
        } catch {}
    }
    const fusionSteps = kind === "fusion" && fusionTier(tier) === "max"
        ? "Pick Auto → GitHub Copilot Fusion → Max and Autopilot, then"
        : "Pick Auto → GitHub Copilot Fusion and Autopilot, then";
    const fusionTail = (didCopy) => didCopy
        ? `${fusionSteps} paste the copied seed prompt and send.`
        : `${fusionSteps} copy the seed prompt from this card (📋 Copy, or select it) and send it.`;

    const opened = folderOpened || repoLinkOpened || linkOpened;
    let message;
    let messageIfCopied;
    if (!opened) {
        message = `Couldn't open the Copilot app. Add ${clonePath || repo} as a project there and start a session.`;
    } else if (isItem && awaitingAllow) {
        message = `No local clone, so this opened ${repo} on GitHub in the Copilot app. Click Allow to add it as a project, then click this button again to open ${itemLabel}.`;
    } else if (isItem && linkOpened) {
        message = `Opened ${itemLabel} in the Copilot app${folderOpened ? ` (${repo} is added as a project)` : ""}. Start a session from it there.`;
    } else if (isItem) {
        message = folderOpened
            ? `Opened ${repo} in the Copilot app, but couldn't open ${itemLabel}. Open it from the project, or at ${itemUrl}.`
            : `Couldn't open ${itemLabel} in the Copilot app. Open it at ${itemUrl}.`;
    } else {
        const lead = folderOpened
            ? `Opened ${repo} in the Copilot app, ready for a new session.`
            : `No local clone, so this opened ${repo} on GitHub in the Copilot app. Click Allow to add it as a project, then start a new session.`;
        if (kind === "fusion") {
            message = `${lead} ${fusionTail(copied)}`;
            if (!copied) messageIfCopied = `${lead} ${fusionTail(true)}`;
        } else {
            message = folderOpened ? `${lead} Type your first prompt there.` : lead;
        }
    }
    return { sent: false, standalone: true, folderOpened, repoLinkOpened, linkOpened, itemLink, itemUrl, opened, copied, message, ...(messageIfCopied ? { messageIfCopied } : {}) };
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

// Fallback for when the canvas webview blocks navigator.clipboard.
function copyToClipboard(text) {
    const candidates = process.platform === "darwin" ? [["pbcopy", []]]
        : process.platform === "win32" ? [["clip", []]]
        : [["wl-copy", []], ["xclip", ["-selection", "clipboard"]], ["xsel", ["--clipboard", "--input"]]];
    for (const [cmd, args] of candidates) {
        // Ignore stdout/stderr: xclip forks a clipboard owner that keeps them open, which would block until the timeout.
        const res = spawnSync(cmd, args, { input: text, stdio: ["pipe", "ignore", "ignore"], timeout: 5000, shell: process.platform === "win32" });
        if (res.status === 0) return { copied: true };
    }
    throw new CanvasError("no_clipboard", "Could not copy to the clipboard; select the prompt text and copy it by hand.");
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
            return json(res, 200, { templates: loadTemplates(), runs: allRuns().map((r) => summary(r)), cleanup: cleanup.state, standalone: isStandalone() });
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
                return json(res, 200, await openSession(findRun(body.id), body.kind || "repo", body.target, body.tier));
            }
            if (url.pathname === "/api/copy-seed") return json(res, 200, copyToClipboard(seedPromptFor(findRun(body.id), body.target).text));
            if (url.pathname === "/api/open-vscode") return json(res, 200, openInVSCode(findRun(body.id)));
            if (url.pathname === "/api/open-answer-key") return json(res, 200, openAnswerKey(findRun(body.id)));
            if (url.pathname === "/api/cleanup/preview") return json(res, 200, await cleanup.preview(body));
            if (url.pathname === "/api/cleanup/delete") return json(res, 200, await cleanup.remove(body));
            if (url.pathname === "/api/cleanup/reset") return json(res, 200, cleanup.reset());
            if (url.pathname === "/api/clear") {
                store.clear();
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
                    handler: async () => allRuns().map((r) => summary(r)).map(({ logTail, ...r }) => r),
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
                    name: "run_with_fusion",
                    description: "For demos with a seed prompt: open a new autopilot session in the demo repo that runs a seed prompt with the GitHub Copilot Fusion model (latest run and first prompt by default). Call once per prompt to compare them.",
                    inputSchema: {
                        type: "object",
                        properties: {
                            ...runIdInput.properties,
                            prompt: { type: "string", description: "Seed prompt label (e.g. Single, Cascade, Critique) for demos with several prompts; defaults to the first." },
                            tier: { type: "string", enum: ["high", "max"], description: "Fusion tier: high (the picker's Standard/High, default) or max." },
                        },
                    },
                    handler: async (ctx) => {
                        const run = findRun(ctx.input?.runId);
                        if (run.status !== "succeeded" || run.result.deleted) throw new CanvasError("not_ready", "That demo repo is not ready.");
                        const seed = seedPromptFor(run, ctx.input?.prompt);
                        const tier = fusionTier(ctx.input?.tier);
                        return { ...(await openSession(run, "fusion", seed.label ?? 0, tier)), seedPrompt: seed.text, tier, ...(seed.label ? { seedLabel: seed.label } : {}) };
                    },
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
