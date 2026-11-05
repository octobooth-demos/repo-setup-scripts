// Seed prompt tests for the Demo Launcher extension (node --test tests/demo-launcher.test.mjs).
// The extension joins a Copilot session at import time, so a child process loads it with a
// stub @github/copilot-sdk/extension and a temp COPILOT_HOME, and records what it would send.

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CONFIG = JSON.parse(readFileSync(join(ROOT, "config.json"), "utf8"));

const STUB = `
export class CanvasError extends Error {
    constructor(code, message) { super(message); this.code = code; }
}
export const createCanvas = (spec) => spec;
export async function joinSession({ canvases }) {
    globalThis.__canvas = canvases[0];
    globalThis.__sent = [];
    return { workspacePath: null, send: async (m) => { globalThis.__sent.push(m.prompt); }, log() {} };
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
await import(process.env.EXTENSION_URL);
const canvas = globalThis.__canvas;
const action = (name) => canvas.actions.find((a) => a.name === name).handler;
const out = {};
const call = async (key, fn) => {
    try { out[key] = await fn(); } catch (e) { out[key] = { error: e.code || e.message }; }
};
const base = (await canvas.open({ input: {} })).url;
out.state = await (await fetch(base + "api/state")).json();
await call("routingDefault", () => action("run_with_fusion")({ input: { runId: "routing" } }));
await call("routingCritique", () => action("run_with_fusion")({ input: { runId: "routing", prompt: "critique" } }));
await call("routingUnknown", () => action("run_with_fusion")({ input: { runId: "routing", prompt: "Nope" } }));
await call("blank", () => action("run_with_fusion")({ input: { runId: "blank" } }));
const post = (body) => fetch(base + "api/open-session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());
out.httpCascade = await post({ id: "routing", kind: "fusion", target: 1 });
out.httpOutOfRange = await post({ id: "routing", kind: "fusion", target: 7 });
out.sent = globalThis.__sent;
console.log("__RESULT__" + JSON.stringify(out));
process.exit(0);
`;

// Copies the launcher, config.json, and resources into a temp repo root so a test can use a
// modified config; the extension reads config.json relative to its own location.
function runDriver(editConfig = (c) => c, driver = DRIVER) {
    const dir = mkdtempSync(join(tmpdir(), "demo-launcher-test-"));
    try {
        const root = join(dir, "repo");
        cpSync(join(ROOT, ".github", "extensions", "demo-launcher"), join(root, ".github", "extensions", "demo-launcher"), { recursive: true });
        cpSync(join(ROOT, "resources"), join(root, "resources"), { recursive: true });
        writeFileSync(join(root, "config.json"), JSON.stringify(editConfig(structuredClone(CONFIG))));
        const extensionUrl = pathToFileURL(join(root, ".github", "extensions", "demo-launcher", "extension.mjs")).href;
        const stub = join(dir, "stub.mjs");
        const hooks = join(dir, "hooks.mjs");
        const driverFile = join(dir, "driver.mjs");
        writeFileSync(stub, STUB);
        writeFileSync(hooks, HOOKS(pathToFileURL(stub).href));
        writeFileSync(driverFile, driver);
        const home = join(dir, "copilot-home");
        const artifacts = join(home, "extensions", "demo-launcher", "artifacts");
        mkdirSync(artifacts, { recursive: true });
        const now = new Date().toISOString();
        const run = (id, template, repo) => ({
            id, template, templateName: template, status: "succeeded", startedAt: now, finishedAt: now, updatedAt: now,
            options: {}, result: { repo, repoUrl: `https://github.com/${repo}` }, log: "",
        });
        writeFileSync(join(artifacts, "runs.json"), JSON.stringify({
            version: 2, clearedAt: 0,
            runs: [run("routing", "fusion-routing", "demo-user/fusion-routing-1234"), run("blank", "fusion-blank", "demo-user/fusion-blank-1234")],
        }));
        const res = spawnSync(process.execPath, [driverFile], {
            env: { ...process.env, COPILOT_HOME: home, HOOKS_URL: pathToFileURL(hooks).href, EXTENSION_URL: extensionUrl },
            encoding: "utf8",
            timeout: 60000,
        });
        const line = (res.stdout || "").split("\n").find((l) => l.startsWith("__RESULT__"));
        assert.ok(line, `driver produced no result (exit ${res.status}):\n${res.stdout}\n${res.stderr}`);
        return JSON.parse(line.slice("__RESULT__".length));
    } finally {
        rmSync(dir, { recursive: true, force: true });
    }
}

const out = runDriver();
const routingConfig = CONFIG.repos.find((r) => r.key === "fusion-routing");
const promptText = (file) => readFileSync(join(ROOT, file), "utf8").trim();
const kickoffOf = (prompt) => JSON.parse(prompt.match(/kickoff object \(don't change the prompt text\): (\{.*?\})\./)[1]);

test("state lists labeled seed prompts for fusion-routing and one unlabeled prompt for fusion-blank", () => {
    const routing = out.state.templates.find((t) => t.key === "fusion-routing");
    assert.deepEqual(routing.seedPrompts.map((p) => p.label), routingConfig.seed_prompts.map((p) => p.label));
    assert.deepEqual(routing.seedPrompts.map((p) => p.text), routingConfig.seed_prompts.map((p) => promptText(p.file)));
    const blank = out.state.templates.find((t) => t.key === "fusion-blank");
    assert.deepEqual(blank.seedPrompts, [{ label: null, text: promptText("resources/fusion-blank/seed-prompt.txt") }]);
    const plain = out.state.templates.find((t) => t.key === "octocart");
    assert.deepEqual(plain.seedPrompts, []);
});

test("run_with_fusion runs the first prompt by default and names the session after its label", () => {
    assert.equal(out.routingDefault.seedLabel, "Single");
    const prompt = out.sent[0];
    assert.deepEqual(kickoffOf(prompt), {
        prompt: promptText("resources/fusion-routing/single.txt"), mode: "autopilot", model: "auto", auto_tier: "hydrafusion",
    });
    assert.match(prompt, /Set the session name to "\[Fusion - Single\] "/);
});

test("run_with_fusion picks a prompt by label (case-insensitive) and rejects unknown labels", () => {
    assert.equal(out.routingCritique.seedLabel, "Critique");
    assert.equal(kickoffOf(out.sent[1]).prompt, promptText("resources/fusion-routing/critique.txt"));
    assert.match(out.sent[1], /\[Fusion - Critique\] /);
    assert.equal(out.routingUnknown.error, "bad_seed_prompt");
});

test("fusion-blank keeps its original single-prompt session request", () => {
    assert.equal(out.blank.seedLabel, undefined);
    const prompt = out.sent[2];
    assert.equal(kickoffOf(prompt).prompt, promptText("resources/fusion-blank/seed-prompt.txt"));
    assert.ok(prompt.startsWith('[Demo Launcher] Run the "fusion-blank" seed prompt with GitHub Copilot Fusion'));
    assert.doesNotMatch(prompt, /session name/);
});

test("the canvas buttons pick a prompt by index", () => {
    assert.equal(out.httpCascade.sent, true);
    assert.equal(kickoffOf(out.sent[3]).prompt, promptText("resources/fusion-routing/cascade.txt"));
    assert.match(out.sent[3], /\[Fusion - Cascade\] /);
    assert.match(out.httpOutOfRange.error, /no seed prompt/);
    assert.equal(out.sent.length, 4);
});

// A driver that only reports the routing template and what run_with_fusion does with it.
const COLLISION_DRIVER = `
import { register } from "node:module";
register(process.env.HOOKS_URL);
await import(process.env.EXTENSION_URL);
const canvas = globalThis.__canvas;
const base = (await canvas.open({ input: {} })).url;
const state = await (await fetch(base + "api/state")).json();
const out = { template: state.templates.find((t) => t.key === "fusion-routing") };
const run = canvas.actions.find((a) => a.name === "run_with_fusion").handler;
try { out.run = await run({ input: { runId: "routing", prompt: "Cascade" } }); } catch (e) { out.run = { error: e.code }; }
out.sent = globalThis.__sent;
console.log("__RESULT__" + JSON.stringify(out));
process.exit(0);
`;

const withRoutingLabels = (labels) => (config) => {
    const routing = config.repos.find((r) => r.key === "fusion-routing");
    routing.seed_prompts.forEach((p, i) => { p.label = labels[i]; });
    return config;
};

for (const [name, labels] of [
    ["labels that differ only in case", ["Single", "single", "Critique"]],
    ["labels that share their first 40 characters", ["Single", `Cascade ${"x".repeat(33)} one`, `Cascade ${"x".repeat(33)} two`]],
    ["labels that differ only in control characters or outer spaces", ["Single", "Cascade\t", " Cascade "]],
]) {
    test(`seed prompts with ${name} are rejected instead of launching the wrong prompt`, () => {
        const result = runDriver(withRoutingLabels(labels), COLLISION_DRIVER);
        assert.deepEqual(result.template.seedPrompts, []);
        assert.match(result.template.seedPromptError, /collide/);
        assert.equal(result.run.error, "bad_seed_prompts");
        assert.deepEqual(result.sent, []);
    });
}

test("labels stay distinct when only non-ASCII letters differ in case, matching the setup scripts", () => {
    const result = runDriver(withRoutingLabels(["Single", "Éclair", "éclair"]), COLLISION_DRIVER);
    assert.equal(result.template.seedPromptError, undefined);
    assert.deepEqual(result.template.seedPrompts.map((p) => p.label), ["Single", "Éclair", "éclair"]);
});
