// Cleanup for the Demo Launcher canvas. Finding candidates reuses the scripts'
// own `--cleanup --dry-run` filter (demo-generated topic + age cutoff), then only
// the repos the user confirmed are deleted, so a repo created in between is never touched.

import { spawn, spawnSync } from "node:child_process";
import { existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { CanvasError } from "@github/copilot-sdk/extension";

const REPOS_DIR = join(homedir(), "repos");

export function createCleanup({ repoRoot, scriptEnv, scriptCommand, broadcast, onRepoDeleted, log }) {
    let state = idle();

    function idle() {
        return { status: "idle", owner: null, olderThanHours: 24, candidates: [], deleted: [], failed: [], log: "", error: null, needsDeleteScope: false };
    }

    function publish() {
        broadcast("cleanup", state);
    }

    function append(text) {
        state.log = (state.log + text).slice(-50_000);
    }

    function localClone(fullName) {
        const path = resolve(REPOS_DIR, fullName.split("/")[1]);
        if (!path.startsWith(REPOS_DIR + sep) || !existsSync(join(path, ".git"))) return null;
        const remote = spawnSync("git", ["-C", path, "remote", "get-url", "origin"], { encoding: "utf8" });
        const url = (remote.stdout || "").trim().replace(/\.git$/, "").toLowerCase();
        return url.endsWith(`/${fullName.toLowerCase()}`) || url.endsWith(`:${fullName.toLowerCase()}`) ? path : null;
    }

    function run(cmd, args, env) {
        return new Promise((done) => {
            const child = spawn(cmd, args, { cwd: repoRoot, env, stdio: ["ignore", "pipe", "pipe"] });
            let out = "";
            const onData = (c) => {
                out += c;
                append(c.toString());
                publish();
            };
            child.stdout.on("data", onData);
            child.stderr.on("data", onData);
            child.on("error", (e) => done({ code: null, out: out + e.message }));
            child.on("close", (code) => done({ code, out }));
        });
    }

    async function preview({ owner, olderThanHours = 24 } = {}) {
        if (state.status === "previewing" || state.status === "deleting") throw new CanvasError("busy", "Cleanup is already running.");
        const hours = Number(olderThanHours);
        if (!Number.isInteger(hours) || hours < 0) throw new CanvasError("invalid_options", "olderThanHours must be a whole number ≥ 0.");
        owner = owner?.trim() || null;
        state = { ...idle(), status: "previewing", owner, olderThanHours: hours };
        publish();

        const { cmd, args } = scriptCommand({
            sh: ["--cleanup", "--dry-run", "--older-than", String(hours), ...(owner ? ["--owner", owner] : [])],
            win: ["-Cleanup", "-DryRun", "-OlderThanHours", String(hours), ...(owner ? ["-Owner", owner] : [])],
        });
        const { code, out } = await run(cmd, args, scriptEnv());
        if (code !== 0) {
            state.status = "error";
            state.error = `Finding repos failed (exit ${code ?? "?"}). See the log.`;
            publish();
            return state;
        }
        const resolvedOwner = out.match(/repos owned by (\S+) older than/)?.[1];
        state.owner = resolvedOwner || owner;
        state.isOrg = false;
        if (state.owner) {
            const who = spawnSync("gh", ["api", `users/${state.owner}`, "--jq", ".type"], { env: scriptEnv(), encoding: "utf8" });
            state.isOrg = (who.stdout || "").trim() === "Organization";
        }
        state.candidates = [...out.matchAll(/^\s+([\w.-]+\/[\w.-]+)\s+\(created (\S+)\)\s*$/gm)].map((m) => ({
            repo: m[1],
            createdAt: m[2],
            clonePath: localClone(m[1]),
        }));
        state.status = "preview";
        publish();
        return state;
    }

    async function remove({ repos, removeClones = false } = {}) {
        if (state.status !== "preview" && state.status !== "done") throw new CanvasError("no_preview", "Find repos to clean up first.");
        const allowed = new Map(state.candidates.map((c) => [c.repo, c]));
        const selected = (repos ?? [...allowed.keys()]).filter((r) => allowed.has(r));
        if (!selected.length) throw new CanvasError("nothing_selected", "No repos from the preview were selected.");

        state.status = "deleting";
        state.deleted = [];
        state.failed = [];
        append(`\n🗑️  Deleting ${selected.length} repo(s)...\n`);
        publish();

        const env = scriptEnv();
        for (const repo of selected) {
            const { code, out } = await run("gh", ["repo", "delete", repo, "--yes"], env);
            if (code === 0) {
                state.deleted.push(repo);
                append(`🗑️  Deleted ${repo}\n`);
                onRepoDeleted(repo);
                const clone = allowed.get(repo).clonePath;
                if (removeClones && clone) {
                    try {
                        rmSync(clone, { recursive: true, force: true });
                        append(`📁 Removed local clone ${clone}\n`);
                    } catch (e) {
                        append(`⚠️  Could not remove ${clone}: ${e.message}\n`);
                    }
                }
            } else {
                state.failed.push(repo);
                if (/delete_repo/.test(out)) state.needsDeleteScope = true;
            }
            publish();
        }
        if (state.needsDeleteScope) append("❌ Deleting repos needs the delete_repo scope. Run:\n   gh auth refresh -h github.com -s delete_repo\n");
        state.status = "done";
        state.candidates = state.candidates.filter((c) => !state.deleted.includes(c.repo));
        publish();
        log(`Demo cleanup: deleted ${state.deleted.length}, failed ${state.failed.length}.`, state.failed.length ? "warning" : "info");
        return state;
    }

    return {
        get state() {
            return state;
        },
        preview,
        remove,
        reset() {
            if (state.status === "previewing" || state.status === "deleting") return state;
            state = idle();
            publish();
            return state;
        },
    };
}
