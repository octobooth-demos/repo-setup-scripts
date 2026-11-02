// Run history shared by every Demo Launcher process on this machine.
//
// The app starts one extension process per chat (plus standalone canvases), and they all
// use the same runs.json. So nothing here assumes this process owns the file:
// - every write re-reads the file under a lock, merges by run id (newest updatedAt wins),
//   and replaces it atomically (temp file + rename);
// - reads pick up other processes' changes (fs.watch plus a cheap mtime poll);
// - "Clear history" stores a clearedAt watermark, so runs that had finished by then
//   aren't brought back by a process that still has them in memory;
// - a cleaned-up repo's `deleted` flag is sticky, so an older copy can't undo it;
// - a running run is only marked interrupted when the process that owns it is gone.

import { readFileSync, writeFileSync, renameSync, unlinkSync, openSync, closeSync, statSync, mkdirSync, watch } from "node:fs";
import { basename, dirname } from "node:path";
import { randomUUID } from "node:crypto";

const LOCK_STALE_MS = 10_000;
const LOCK_WAIT_MS = 2_000;
const sleeper = new Int32Array(new SharedArrayBuffer(4));
const sleep = (ms) => Atomics.wait(sleeper, 0, 0, ms);

export function pidAlive(pid) {
    if (!Number.isInteger(pid) || pid <= 0) return false;
    try {
        process.kill(pid, 0);
        return true;
    } catch (e) {
        return e.code === "EPERM";
    }
}

const time = (iso) => (iso ? Date.parse(iso) || 0 : 0);

/**
 * @param {object} opts
 * @param {string} opts.file          path to runs.json
 * @param {number} opts.maxRuns       newest runs to keep
 * @param {(run) => void} [opts.normalize]  fix up runs read from disk (e.g. renamed templates)
 * @param {(id: string) => boolean} [opts.isOwned]  true while this process runs that create-repo
 * @param {(change: {removed: boolean, changed: object[]}) => void} [opts.onChange]
 *        called when another process changed the history (or an orphaned run was interrupted)
 */
export function createRunStore({ file, maxRuns, normalize = () => {}, isOwned = () => false, onChange = () => {} }) {
    const dir = dirname(file);
    const lockFile = `${file}.lock`;
    let runs = [];
    let clearedAt = 0;
    const dirty = new Set();
    let seenKey = null;
    let writeTimer = null;
    let watcher = null;
    let poller = null;
    let corruptReads = 0;

    function statKey() {
        try {
            const s = statSync(file);
            return `${s.mtimeMs}:${s.size}:${s.ino}`;
        } catch {
            return "missing";
        }
    }

    // A missing file is an empty history. Returns null when the file can't be read right now
    // and { corrupt: true } when it isn't valid JSON; callers keep what they have and retry.
    function readDisk() {
        let text;
        try {
            text = readFileSync(file, "utf8");
        } catch (e) {
            return e.code === "ENOENT" ? { clearedAt: 0, runs: [] } : null;
        }
        try {
            const data = JSON.parse(text);
            if (Array.isArray(data)) return { clearedAt: 0, runs: data }; // format before v2
            if (!data || typeof data !== "object") return { corrupt: true };
            return { clearedAt: Number(data.clearedAt) || 0, runs: Array.isArray(data.runs) ? data.runs : [] };
        } catch {
            return { corrupt: true };
        }
    }

    function ownerGone(run) {
        if (run.status !== "running" || isOwned(run.id)) return false;
        return run.ownerPid === process.pid || !pidAlive(run.ownerPid);
    }

    function clearedAway(run) {
        return run.status !== "running" && time(run.finishedAt || run.startedAt) <= clearedAt;
    }

    // Finished beats interrupted beats running, so a stale copy that only had cleanup's
    // deleted flag added can't undo a completion; within the same state, newest wins.
    const RANK = { running: 0, interrupted: 1 };
    const rank = (r) => RANK[r.status] ?? 2;
    function newer(a, b) {
        if (rank(a) !== rank(b)) return rank(a) > rank(b) ? a : b;
        return (a.updatedAt || 0) > (b.updatedAt || 0) ? a : b;
    }

    function stickyDeleted(target, ...others) {
        if (target.result && !target.result.deleted && others.some((o) => o?.result?.deleted)) {
            target.result.deleted = true;
            return true;
        }
        return false;
    }

    // Merge the file's runs into memory. Runs this process owns keep their object identity
    // (startRun's callbacks mutate them); everything else takes the newest copy.
    function reconcile(disk) {
        const before = new Map(runs.map((r) => [r.id, { obj: r, updatedAt: r.updatedAt || 0, deleted: !!r.result?.deleted }]));
        clearedAt = Math.max(clearedAt, disk.clearedAt);
        const local = new Map(runs.map((r) => [r.id, r]));
        const next = new Map();
        for (const d of disk.runs) {
            if (!d || typeof d.id !== "string" || next.has(d.id)) continue;
            normalize(d);
            d.result ||= {};
            const mine = local.get(d.id);
            const pick = !mine ? d : isOwned(mine.id) ? mine : newer(mine, d) === mine ? mine : d;
            stickyDeleted(pick, mine, d);
            next.set(d.id, pick);
        }
        for (const r of runs) {
            if (!next.has(r.id) && (isOwned(r.id) || dirty.has(r.id))) next.set(r.id, r);
        }
        const now = new Date().toISOString();
        for (const r of next.values()) {
            if (ownerGone(r)) {
                r.status = "interrupted";
                r.finishedAt ||= now;
                r.updatedAt = Date.now();
                dirty.add(r.id);
            }
        }
        runs = [...next.values()]
            .filter((r) => !clearedAway(r))
            .sort((a, b) => time(b.startedAt) - time(a.startedAt))
            .filter((r, i) => i < maxRuns || isOwned(r.id));
        for (const id of dirty) if (!runs.some((r) => r.id === id)) dirty.delete(id);

        const ids = new Set(runs.map((r) => r.id));
        const removed = [...before.keys()].some((id) => !ids.has(id));
        const changed = runs.filter((r) => {
            const b = before.get(r.id);
            return !b || b.obj !== r || b.updatedAt !== (r.updatedAt || 0) || b.deleted !== !!r.result?.deleted;
        });
        return { removed, changed };
    }

    function report(change) {
        if (change.removed || change.changed.length) onChange(change);
    }

    // Lock files hold "<pid> <token>". A lock is only reclaimed when its holder is dead, or
    // it has no holder (a crash between create and write) and is old. Reclaiming happens
    // under a second lock and re-checks the token, so it can't remove a successor's lock.
    const token = `${process.pid} ${randomUUID()}`;
    const reclaimFile = `${lockFile}.reclaim`;

    function tryCreate(path) {
        try {
            const fd = openSync(path, "wx");
            try {
                writeFileSync(fd, token);
            } finally {
                closeSync(fd);
            }
            return true;
        } catch (e) {
            if (e.code === "EEXIST") return false;
            throw e;
        }
    }

    function holderOf(path) {
        try {
            const text = readFileSync(path, "utf8");
            return { text, pid: Number(text.split(" ")[0]), age: Date.now() - statSync(path).mtimeMs };
        } catch {
            return null; // gone
        }
    }

    const abandoned = (h) => (h.pid > 0 ? !pidAlive(h.pid) : h.age > LOCK_STALE_MS);

    function removeIfSame(path, text) {
        const now = holderOf(path);
        if (now && now.text === text) unlinkSync(path);
    }

    function reclaim(stale) {
        if (!tryCreate(reclaimFile)) {
            const r = holderOf(reclaimFile);
            if (r && abandoned(r)) removeIfSame(reclaimFile, r.text);
            return;
        }
        try {
            removeIfSame(lockFile, stale.text);
        } finally {
            removeIfSame(reclaimFile, token);
        }
    }

    function lock() {
        const deadline = Date.now() + LOCK_WAIT_MS;
        for (;;) {
            try {
                if (tryCreate(lockFile)) return true;
                const h = holderOf(lockFile);
                // Even after a reclaim, go through the deadline and backoff below: a stalled
                // reclaimer must make flush() give up and retry later, not spin.
                if (h && abandoned(h)) reclaim(h);
            } catch {
                return false;
            }
            if (Date.now() > deadline) return false;
            sleep(10);
        }
    }

    function unlock() {
        try {
            removeIfSame(lockFile, token);
        } catch {
            // already gone
        }
    }

    // Windows can refuse a rename while another process has the target open, so retry
    // briefly. Never fall back to rewriting runs.json in place: readers don't lock.
    function replaceFile(text) {
        const tmp = `${file}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
        writeFileSync(tmp, text);
        for (let i = 0; ; i++) {
            try {
                renameSync(tmp, file);
                return;
            } catch (e) {
                if (i >= 10 || !["EPERM", "EACCES", "EBUSY"].includes(e.code)) {
                    try {
                        unlinkSync(tmp);
                    } catch {
                        // best effort
                    }
                    throw e;
                }
                sleep(25);
            }
        }
    }

    function writeNow() {
        clearTimeout(writeTimer);
        writeTimer = null;
        try {
            mkdirSync(dir, { recursive: true });
        } catch {
            // best effort
        }
        if (!lock()) {
            schedule(); // someone else is writing; keep our changes and retry
            return false;
        }
        try {
            let disk = readDisk();
            if (!disk) throw new Error("runs.json is unreadable right now");
            if (disk.corrupt) {
                // A torn write from an older launcher heals on retry; a really broken file is
                // set aside (not deleted) after a few tries so history can be saved again.
                if (++corruptReads < 3) throw new Error("runs.json is not valid JSON");
                try {
                    renameSync(file, `${file}.corrupt-${Date.now()}`);
                } catch {
                    // replaceFile below replaces it anyway
                }
                disk = { clearedAt, runs: [...runs] }; // rebuild from what this process knows
            }
            corruptReads = 0;
            const change = reconcile(disk);
            replaceFile(JSON.stringify({ version: 2, clearedAt, runs }, null, 2));
            dirty.clear();
            seenKey = statKey();
            report(change);
            return true;
        } catch {
            schedule();
            return false;
        } finally {
            unlock();
        }
    }

    function schedule() {
        if (!writeTimer) writeTimer = setTimeout(writeNow, 250);
    }

    /** Pick up changes from other processes. Cheap when nothing changed. */
    function sync() {
        const key = statKey();
        if (key !== seenKey) {
            const disk = readDisk();
            if (disk && !disk.corrupt) {
                seenKey = key;
                report(reconcile(disk));
            }
        }
        // An owner can die without touching the file, so check liveness every time.
        if (runs.some(ownerGone)) report(reconcile({ clearedAt, runs: [...runs] }));
        if (dirty.size) schedule();
        return runs;
    }

    /** Record that this process changed `run` (or added it) and save soon. */
    function touch(run) {
        run.updatedAt = Math.max(Date.now(), (run.updatedAt || 0) + 1);
        dirty.add(run.id);
        schedule();
    }

    function add(run) {
        run.ownerPid = process.pid;
        if (!runs.includes(run)) runs.unshift(run);
        touch(run);
    }

    /** Remove every finished run, here and in every other process. */
    function clear() {
        sync();
        clearedAt = Date.now();
        runs = runs.filter((r) => r.status === "running");
        writeNow();
    }

    function watchFile() {
        if (watcher || poller) return;
        let debounce = null;
        const later = () => {
            clearTimeout(debounce);
            debounce = setTimeout(sync, 75);
        };
        try {
            mkdirSync(dir, { recursive: true });
            watcher = watch(dir, (_event, name) => {
                if (!name || String(name) === basename(file)) later();
            });
            watcher.on("error", () => {});
            watcher.unref?.();
        } catch {
            watcher = null; // the poll below still catches changes
        }
        poller = setInterval(sync, 2000);
        poller.unref?.();
    }

    function close() {
        watcher?.close();
        clearInterval(poller);
        watcher = poller = null;
        if (dirty.size) writeNow();
    }

    process.on("exit", () => {
        if (dirty.size) writeNow();
    });

    sync();

    return {
        get runs() {
            return runs;
        },
        sync,
        touch,
        add,
        clear,
        flush: writeNow,
        watch: watchFile,
        close,
    };
}
