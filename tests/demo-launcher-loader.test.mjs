// Tests for the Demo Launcher loader (node --test tests/demo-launcher-loader.test.mjs).
// Each case copies the loader to a temp extensions folder (as a URL install or install.sh
// would) and loads it in a child process with a stub @github/copilot-sdk/extension.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const LOADER = join(ROOT, ".github", "extensions", "demo-launcher-loader", "extension.mjs");

const STUB = `
export const createCanvas = (spec) => spec;
export async function joinSession(opts) {
    globalThis.__joined = (globalThis.__joined || 0) + 1;
    globalThis.__canvases = opts.canvases || [];
    globalThis.__logs = [];
    return { log: (m, o) => globalThis.__logs.push({ m, o }) };
}
`;

const HOOKS = (stubUrl) => `
export async function resolve(specifier, context, next) {
    if (specifier === "@github/copilot-sdk/extension") return { url: ${JSON.stringify(stubUrl)}, shortCircuit: true };
    return next(specifier, context);
}
`;

const DRIVER = `
import { register } from "node:module";
register(process.env.HOOKS_URL);
await import(process.env.LOADER_URL);
const out = { joined: globalThis.__joined || 0, launcher: globalThis.__launcher || null, canvases: (globalThis.__canvases || []).map((c) => c.id), logs: globalThis.__logs || [] };
const canvas = (globalThis.__canvases || [])[0];
if (canvas?.open) {
    const { url } = await canvas.open({ input: {} });
    out.html = await (await fetch(url)).text();
    out.status = await canvas.actions.find((a) => a.name === "setup_status").handler({});
}
console.log("__RESULT__" + JSON.stringify(out));
process.exit(0);
`;

// The fake launcher only records that it was imported (and from which URL).
const FAKE_LAUNCHER = `globalThis.__launcher = import.meta.url; globalThis.__joined = 1;\n`;

function makeTemp(t) {
    // A space in the path checks the file-URL conversion; realpath avoids macOS /var symlinks.
    const dir = realpathSync(mkdtempSync(join(tmpdir(), "loader test-")));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    writeFileSync(join(dir, "stub.mjs"), STUB);
    writeFileSync(join(dir, "hooks.mjs"), HOOKS(pathToFileURL(join(dir, "stub.mjs")).href));
    writeFileSync(join(dir, "driver.mjs"), DRIVER);
    // Sessions run somewhere outside repo-setup-scripts; a .git stops the own-copy walk there.
    mkdirSync(join(dir, "session", ".git"), { recursive: true });
    return dir;
}

function makeCheckout(root) {
    const ext = join(root, ".github", "extensions", "demo-launcher");
    mkdirSync(ext, { recursive: true });
    writeFileSync(join(ext, "extension.mjs"), FAKE_LAUNCHER);
    return join(ext, "extension.mjs");
}

function installLoader(dir, source = LOADER) {
    const target = join(dir, "copilot home", "extensions", "demo-launcher");
    mkdirSync(target, { recursive: true });
    cpSync(source, join(target, "extension.mjs"));
    return join(target, "extension.mjs");
}

function runLoader(dir, loaderFile, { env = {}, cwd = join(dir, "session") } = {}) {
    const home = join(dir, "home");
    mkdirSync(home, { recursive: true });
    const childEnv = { ...process.env, HOME: home, USERPROFILE: home, ...env };
    if (!("DEMO_LAUNCHER_REPO" in env)) delete childEnv.DEMO_LAUNCHER_REPO;
    const res = spawnSync(process.execPath, [join(dir, "driver.mjs")], {
        cwd,
        env: { ...childEnv, HOOKS_URL: pathToFileURL(join(dir, "hooks.mjs")).href, LOADER_URL: pathToFileURL(loaderFile).href },
        encoding: "utf8",
        timeout: 20000,
    });
    const line = res.stdout.split("\n").find((l) => l.startsWith("__RESULT__"));
    assert.ok(line, `loader produced no result:\n${res.stdout}\n${res.stderr}`);
    return JSON.parse(line.slice("__RESULT__".length));
}

test("defaults to ~/repos/repo-setup-scripts and imports it by file URL", (t) => {
    const dir = makeTemp(t);
    const launcher = makeCheckout(join(dir, "home", "repos", "repo-setup-scripts"));
    const out = runLoader(dir, installLoader(dir));
    assert.equal(out.launcher, pathToFileURL(launcher).href);
    assert.deepEqual(out.canvases, []);
});

test("DEMO_LAUNCHER_REPO overrides the default checkout", (t) => {
    const dir = makeTemp(t);
    makeCheckout(join(dir, "home", "repos", "repo-setup-scripts"));
    const launcher = makeCheckout(join(dir, "elsewhere", "my fork"));
    const out = runLoader(dir, installLoader(dir), { env: { DEMO_LAUNCHER_REPO: join(dir, "elsewhere", "my fork") } });
    assert.equal(out.launcher, pathToFileURL(launcher).href);
});

test("a missing checkout registers a Demo Launcher canvas that explains the fix", (t) => {
    const dir = makeTemp(t);
    const out = runLoader(dir, installLoader(dir));
    const expected = join(dir, "home", "repos", "repo-setup-scripts");
    assert.equal(out.launcher, null);
    assert.deepEqual(out.canvases, ["demo-launcher"]);
    assert.equal(out.status.ok, false);
    assert.equal(out.status.repoRoot, expected);
    assert.match(out.status.message, /Clone octobooth-demos\/repo-setup-scripts/);
    assert.match(out.status.message, /DEMO_LAUNCHER_REPO/);
    assert.match(out.html, /gh repo clone octobooth-demos\/repo-setup-scripts/);
    assert.equal(out.logs.length, 1);
    assert.equal(out.logs[0].o.level, "error");
});

test("a session inside a repo with its own copy joins without loading a second launcher", (t) => {
    const dir = makeTemp(t);
    makeCheckout(join(dir, "home", "repos", "repo-setup-scripts"));
    const repo = join(dir, "session repo");
    makeCheckout(repo);
    mkdirSync(join(repo, ".git"));
    mkdirSync(join(repo, "src"));
    const out = runLoader(dir, installLoader(dir), { cwd: join(repo, "src") });
    assert.equal(out.launcher, null);
    assert.equal(out.joined, 1);
    assert.deepEqual(out.canvases, []);
});

test("loaded from a checkout as a project extension, it leaves the canvas to that checkout", (t) => {
    const dir = makeTemp(t);
    makeCheckout(join(dir, "home", "repos", "repo-setup-scripts"));
    const checkout = join(dir, "project");
    makeCheckout(checkout);
    const loaderDir = join(checkout, ".github", "extensions", "demo-launcher-loader");
    mkdirSync(loaderDir);
    cpSync(LOADER, join(loaderDir, "extension.mjs"));
    const out = runLoader(dir, join(loaderDir, "extension.mjs"));
    assert.equal(out.launcher, null);
    assert.equal(out.joined, 1);
});

test("an installed loader under a COPILOT_HOME inside a checkout still loads the configured launcher", (t) => {
    const dir = makeTemp(t);
    const launcher = makeCheckout(join(dir, "home", "repos", "repo-setup-scripts"));
    const repo = join(dir, "repo");
    makeCheckout(repo);
    const target = join(repo, ".copilot", "extensions", "demo-launcher");
    mkdirSync(target, { recursive: true });
    cpSync(LOADER, join(target, "extension.mjs"));
    const out = runLoader(dir, join(target, "extension.mjs"));
    assert.equal(out.launcher, pathToFileURL(launcher).href);
});

test("install.sh writes the same loader with its checkout baked in", { skip: process.platform === "win32" && "install.sh is bash-only" }, (t) => {
    const dir = makeTemp(t);
    // A quote in the checkout path must survive the JS string escaping.
    const checkout = join(dir, 'odd "path" here');
    cpSync(join(ROOT, ".github", "extensions"), join(checkout, ".github", "extensions"), { recursive: true });
    writeFileSync(join(checkout, ".github", "extensions", "demo-launcher", "extension.mjs"), FAKE_LAUNCHER);
    const copilotHome = join(dir, "copilot home");
    const res = spawnSync("bash", [join(checkout, ".github", "extensions", "demo-launcher", "install.sh")], {
        env: { ...process.env, COPILOT_HOME: copilotHome },
        encoding: "utf8",
    });
    assert.equal(res.status, 0, res.stderr);
    const installed = join(copilotHome, "extensions", "demo-launcher", "extension.mjs");
    const source = readFileSync(LOADER, "utf8").split("\n");
    const written = readFileSync(installed, "utf8").split("\n");
    assert.equal(written.length, source.length);
    const changed = written.filter((l, i) => l !== source[i]);
    assert.equal(changed.length, 1);
    assert.match(changed[0], /^const INSTALLED_REPO = ".+"; \/\/ Set by install\.sh\.$/);

    const out = runLoader(dir, installed);
    assert.equal(out.launcher, pathToFileURL(join(checkout, ".github", "extensions", "demo-launcher", "extension.mjs")).href);

    const un = spawnSync("bash", [join(checkout, ".github", "extensions", "demo-launcher", "install.sh"), "--uninstall"], {
        env: { ...process.env, COPILOT_HOME: copilotHome },
        encoding: "utf8",
    });
    assert.equal(un.status, 0, un.stderr);
    assert.throws(() => readFileSync(installed));
});
