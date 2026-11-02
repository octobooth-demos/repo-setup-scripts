// Multi-process tests for the Demo Launcher run store (.github/extensions/demo-launcher/run-store.mjs).
// Several worker processes share one temp runs.json, like several launcher instances do.
//
//   node --test tests/run-store.test.mjs

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, readdirSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createInterface } from "node:readline";

const HERE = fileURLToPath(import.meta.url);
const STORE_MODULE = pathToFileURL(join(dirname(HERE), "..", ".github", "extensions", "demo-launcher", "run-store.mjs")).href;

// ---------- worker: one simulated launcher process ----------

if (process.argv[2] === "worker") {
    const [file, maxRuns, watchFlag] = process.argv.slice(3);
    const { createRunStore } = await import(STORE_MODULE);
    const owned = new Set();
    let changes = 0;
    const store = createRunStore({
        file,
        maxRuns: Number(maxRuns),
        normalize: (r) => {
            if (r.template === "ensemble-blank") r.template = "fusion-blank";
        },
        isOwned: (id) => owned.has(id),
        onChange: () => changes++,
    });
    if (watchFlag === "watch") store.watch();
    const view = (runs) => runs.map((r) => ({ id: r.id, status: r.status, template: r.template, deleted: !!r.result?.deleted }));
    const commands = {
        add({ id, repo }) {
            owned.add(id);
            store.add({ id, template: "t", status: "running", startedAt: new Date().toISOString(), finishedAt: null, result: { repo: repo || null }, log: "" });
        },
        finish({ id }) {
            const run = store.runs.find((r) => r.id === id);
            run.status = "succeeded";
            run.finishedAt = new Date().toISOString();
            store.touch(run);
            owned.delete(id);
        },
        markDeleted({ repo }) {
            for (const r of store.sync()) {
                if (r.result.repo === repo) {
                    r.result.deleted = true;
                    store.touch(r);
                }
            }
        },
        // Touch a run from this process's (possibly stale) memory, without syncing first.
        bump({ id }) {
            const run = store.runs.find((r) => r.id === id);
            if (run) {
                run.log += ".";
                store.touch(run);
            }
        },
        clear: () => store.clear(),
        flush: () => store.flush(),
        list: () => view(store.sync()),
        memory: () => view(store.runs),
        changes: () => changes,
        pid: () => process.pid,
        cpu: () => { const u = process.cpuUsage(); return u.user + u.system; },
    };
    const rl = createInterface({ input: process.stdin });
    rl.on("line", (line) => {
        const { seq, cmd, args } = JSON.parse(line);
        let reply;
        try {
            reply = { seq, ok: commands[cmd](args || {}) ?? null };
        } catch (e) {
            reply = { seq, error: e.stack };
        }
        process.stdout.write(JSON.stringify(reply) + "\n");
    });
    rl.on("close", () => process.exit(0));
} else {
    defineTests();
}

// ---------- test driver ----------

function startWorker(file, { maxRuns = 30, watch = false } = {}) {
    const child = spawn(process.execPath, [HERE, "worker", file, String(maxRuns), watch ? "watch" : ""], { stdio: ["pipe", "pipe", "inherit"] });
    const pending = new Map();
    let seq = 0;
    createInterface({ input: child.stdout }).on("line", (line) => {
        const msg = JSON.parse(line);
        const p = pending.get(msg.seq);
        pending.delete(msg.seq);
        if (msg.error) p.reject(new Error(msg.error));
        else p.resolve(msg.ok);
    });
    const call = (cmd, args) =>
        new Promise((resolve, reject) => {
            const id = ++seq;
            pending.set(id, { resolve, reject });
            child.stdin.write(JSON.stringify({ seq: id, cmd, args }) + "\n");
        });
    return { child, call, stop: () => child.stdin.end(), kill: () => child.kill("SIGKILL") };
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));
const ids = (list) => list.map((r) => r.id).sort();
const byId = (list, id) => list.find((r) => r.id === id);
const readFile = (file) => JSON.parse(readFileSync(file, "utf8"));

async function waitFor(fn, what, timeout = 5000) {
    const end = Date.now() + timeout;
    for (;;) {
        const value = await fn();
        if (value) return value;
        if (Date.now() > end) assert.fail(`timed out waiting for ${what}`);
        await delay(50);
    }
}

function defineTests() {
    let dir;
    const workers = [];
    const worker = (...a) => {
        const w = startWorker(...a);
        workers.push(w);
        return w;
    };

    test.beforeEach(() => {
        dir = mkdtempSync(join(tmpdir(), "run-store-test-"));
    });
    test.afterEach(async () => {
        for (const w of workers.splice(0)) w.kill();
        await delay(50);
        rmSync(dir, { recursive: true, force: true });
    });

    test("startup normalizes legacy runs and only interrupts runs whose owner is gone", async () => {
        const file = join(dir, "runs.json");
        const keeper = worker(join(dir, "unused.json")); // a live process to own a run
        const livePid = await keeper.call("pid");
        const now = new Date().toISOString();
        writeFileSync(file, JSON.stringify([
            { id: "old", template: "ensemble-blank", status: "succeeded", startedAt: now, finishedAt: now, result: {}, log: "" },
            { id: "orphan", template: "t", status: "running", startedAt: now, finishedAt: null, result: {}, log: "" },
            { id: "live", template: "t", status: "running", ownerPid: livePid, startedAt: now, finishedAt: null, result: {}, log: "" },
        ]));
        const a = worker(file);
        const list = await a.call("list");
        assert.equal(byId(list, "old").template, "fusion-blank");
        assert.equal(byId(list, "orphan").status, "interrupted");
        assert.equal(byId(list, "live").status, "running");
        await a.call("flush");
        const disk = readFile(file);
        assert.equal(disk.version, 2);
        assert.equal(byId(disk.runs, "live").status, "running");
        assert.equal(byId(disk.runs, "orphan").status, "interrupted");
    });

    test("runs created concurrently in two processes all survive", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        const adds = [];
        for (let i = 0; i < 12; i++) {
            adds.push(a.call("add", { id: `a${i}` }), b.call("add", { id: `b${i}` }));
            if (i % 3 === 0) adds.push(a.call("flush"), b.call("flush"));
        }
        await Promise.all(adds);
        await Promise.all([a.call("flush"), b.call("flush")]);
        const expected = [...Array(12).keys()].flatMap((i) => [`a${i}`, `b${i}`]).sort();
        assert.deepEqual(ids(readFile(file).runs), expected);
        assert.deepEqual(ids(await a.call("list")), expected);
        assert.deepEqual(ids(await b.call("list")), expected);
        // Each sees the other's live runs as running, not interrupted.
        assert.ok((await a.call("list")).every((r) => r.status === "running"));
    });

    test("finishes and cleanup deletes propagate, and deleted stays sticky", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        await a.call("add", { id: "r1", repo: "me/demo-1" });
        await a.call("flush");
        assert.equal(byId(await b.call("list"), "r1").status, "running");

        await a.call("finish", { id: "r1" });
        await a.call("flush");
        assert.equal(byId(await b.call("list"), "r1").status, "succeeded");

        await b.call("markDeleted", { repo: "me/demo-1" });
        await b.call("flush");
        // A changes its stale copy (no deleted flag) after B's delete; deleted must survive.
        await a.call("bump", { id: "r1" });
        await a.call("flush");
        assert.equal(byId(readFile(file).runs, "r1").result.deleted, true);
        assert.equal(byId(await a.call("list"), "r1").deleted, true);
        assert.equal(byId(await b.call("list"), "r1").deleted, true);
    });

    test("Clear history propagates and isn't undone by another process's stale memory", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        for (const id of ["f1", "f2"]) {
            await a.call("add", { id });
            await a.call("finish", { id });
        }
        await a.call("add", { id: "still-running" });
        await a.call("flush");
        assert.deepEqual(ids(await b.call("list")), ["f1", "f2", "still-running"]);

        await b.call("clear");
        // A hasn't synced yet: its memory still has f1/f2. Touch one and write.
        assert.deepEqual(ids(await a.call("memory")), ["f1", "f2", "still-running"]);
        await a.call("bump", { id: "f1" });
        await a.call("flush");

        assert.deepEqual(ids(readFile(file).runs), ["still-running"]);
        assert.deepEqual(ids(await a.call("list")), ["still-running"]);
        assert.deepEqual(ids(await b.call("list")), ["still-running"]);

        // A run that finishes after the clear is kept.
        await a.call("finish", { id: "still-running" });
        await a.call("flush");
        assert.equal(byId(await b.call("list"), "still-running").status, "succeeded");
    });

    test("a run is interrupted only after its owner process dies", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        await b.call("add", { id: "b-run" });
        await b.call("flush");
        const c = worker(file); // starts while B is alive
        assert.equal(byId(await c.call("list"), "b-run").status, "running");
        assert.equal(byId(await a.call("list"), "b-run").status, "running");

        b.kill();
        await waitFor(async () => byId(await a.call("list"), "b-run").status === "interrupted", "b-run to be interrupted");
        await a.call("flush");
        assert.equal(byId(readFile(file).runs, "b-run").status, "interrupted");
        assert.equal(byId(await c.call("list"), "b-run").status, "interrupted");
    });

    test("a watching process is notified of other processes' changes", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file, { watch: true });
        const b = worker(file);
        await a.call("list");
        const before = await a.call("changes");
        await b.call("add", { id: "x" });
        await b.call("flush");
        await waitFor(async () => (await a.call("changes")) > before && byId(await a.call("memory"), "x"), "A to see B's run without asking");
    });

    test("a completion isn't undone by a stale copy that cleanup marked deleted", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        await a.call("add", { id: "r", repo: "me/demo" });
        await a.call("flush");
        assert.equal(byId(await b.call("list"), "r").status, "running");
        await a.call("finish", { id: "r" }); // not saved yet
        await b.call("markDeleted", { repo: "me/demo" }); // newer, but still "running"
        await b.call("flush");
        await a.call("flush");
        for (const list of [readFile(file).runs.map((r) => ({ ...r, deleted: r.result.deleted })), await a.call("list"), await b.call("list")]) {
            assert.equal(byId(list, "r").status, "succeeded");
            assert.equal(byId(list, "r").deleted, true);
        }
    });

    test("a live writer keeps its lock however old it is; a dead writer's lock is reclaimed", async () => {
        const file = join(dir, "runs.json");
        const keeper = worker(join(dir, "unused.json"));
        const livePid = await keeper.call("pid");
        const a = worker(file);
        writeFileSync(`${file}.lock`, `${livePid} someone-else`);
        const old = new Date(Date.now() - 60 * 60 * 1000);
        utimesSync(`${file}.lock`, old, old);
        await a.call("add", { id: "x" });
        assert.equal(await a.call("flush"), false);
        assert.equal(existsSync(file), false);
        assert.equal(readFileSync(`${file}.lock`, "utf8"), `${livePid} someone-else`);

        keeper.kill();
        await delay(100);
        assert.equal(await a.call("flush"), true);
        assert.deepEqual(ids(readFile(file).runs), ["x"]);
        assert.equal(existsSync(`${file}.lock`), false);
    });

    test("a stalled live reclaimer makes flush give up on time instead of spinning", async () => {
        const file = join(dir, "runs.json");
        const keeper = worker(join(dir, "unused.json"));
        const livePid = await keeper.call("pid");
        const a = worker(file);
        writeFileSync(`${file}.lock`, "999999999 dead-writer"); // abandoned main lock
        writeFileSync(`${file}.lock.reclaim`, `${livePid} stalled-reclaimer`);
        await a.call("add", { id: "x" });
        const startCpu = await a.call("cpu");
        const started = Date.now();
        assert.equal(await a.call("flush"), false);
        const elapsed = Date.now() - started;
        const cpuMs = ((await a.call("cpu")) - startCpu) / 1000;
        assert.ok(elapsed < 2000 + 1500, `flush took ${elapsed}ms`);
        assert.ok(cpuMs < elapsed / 2, `busy-spun: ${cpuMs}ms CPU in ${elapsed}ms`);
        assert.equal(readFileSync(`${file}.lock.reclaim`, "utf8"), `${livePid} stalled-reclaimer`);
    });

    test("an unreadable runs.json isn't treated as empty history", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file);
        const b = worker(file);
        await b.call("add", { id: "kept" });
        await b.call("finish", { id: "kept" });
        await b.call("flush");
        assert.deepEqual(ids(await a.call("list")), ["kept"]);
        writeFileSync(file, '{"version":2,"runs":[{"id":"kep'); // torn write
        assert.deepEqual(ids(await a.call("list")), ["kept"]);
        await a.call("add", { id: "new" });
        assert.equal(await a.call("flush"), false); // waits rather than overwriting
        assert.equal(readFileSync(file, "utf8"), '{"version":2,"runs":[{"id":"kep');
        // If it stays broken, it's set aside and history is saved again from memory.
        await waitFor(() => existsSync(file) && readFileSync(file, "utf8").startsWith("{\n"), "runs.json to be rewritten");
        assert.deepEqual(ids(readFile(file).runs), ["kept", "new"]);
        assert.ok(readdirSync(dir).some((f) => f.startsWith("runs.json.corrupt-")));
    });

    test("history is trimmed to the newest runs", async () => {
        const file = join(dir, "runs.json");
        const a = worker(file, { maxRuns: 3 });
        const b = worker(file, { maxRuns: 3 });
        for (const id of ["1", "2", "3", "4", "5"]) {
            const w = Number(id) % 2 ? a : b;
            await w.call("add", { id });
            await w.call("finish", { id });
            await w.call("flush");
            await delay(5);
        }
        assert.deepEqual(ids(readFile(file).runs), ["3", "4", "5"]);
        assert.deepEqual(ids(await a.call("list")), ["3", "4", "5"]);
    });
}
