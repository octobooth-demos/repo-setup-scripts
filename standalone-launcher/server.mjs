#!/usr/bin/env node
// Standalone Demo Launcher: a browser GUI for create-repo on a fixed loopback port. A fallback
// for the Copilot canvas that needs neither the Copilot app nor its SDK.
//
//   node standalone-launcher/server.mjs [--port 4747] [--open]
//
// Env: DEMO_LAUNCHER_PORT, DEMO_LAUNCHER_STATE_DIR (run history location).

import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { configure, listen } from "./core.mjs";

const { values } = parseArgs({
    options: {
        port: { type: "string", default: process.env.DEMO_LAUNCHER_PORT || "4747" },
        open: { type: "boolean", default: false },
        help: { type: "boolean", short: "h", default: false },
    },
});

if (values.help) {
    console.log("Usage: node standalone-launcher/server.mjs [--port 4747] [--open]");
    process.exit(0);
}

const port = Number(values.port);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`Invalid port: ${values.port}`);
    process.exit(2);
}

function defaultStateDir() {
    if (process.platform === "darwin") return join(homedir(), "Library", "Application Support", "demo-launcher");
    if (process.platform === "win32") return join(process.env.LOCALAPPDATA || join(homedir(), "AppData", "Local"), "demo-launcher");
    return join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "demo-launcher");
}

const stamp = () => new Date().toISOString();
configure({
    stateDir: process.env.DEMO_LAUNCHER_STATE_DIR || defaultStateDir(),
    allowedHosts: [`127.0.0.1:${port}`, `localhost:${port}`],
    log: (message, level = "info") => console.log(`${stamp()} [${level}] ${message}`),
});

let url;
try {
    url = await listen({ port, host: "127.0.0.1" });
} catch (e) {
    console.error(e.code === "EADDRINUSE"
        ? `Port ${port} is already in use. Is the Demo Launcher already running? Try http://127.0.0.1:${port}/ or pass --port.`
        : `Could not start the Demo Launcher: ${e.message}`);
    process.exit(1);
}
console.log(`${stamp()} [info] Demo Launcher running at ${url}`);

if (values.open) {
    const [cmd, args] = process.platform === "darwin" ? ["open", [url]]
        : process.platform === "win32" ? ["cmd", ["/c", "start", "", url]]
        : ["xdg-open", [url]];
    spawn(cmd, args, { detached: true, stdio: "ignore" }).on("error", () => {}).unref();
}

for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => process.exit(0));
