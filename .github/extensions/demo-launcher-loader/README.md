# Demo Launcher loader

A small user-level Copilot extension that loads the [Demo Launcher](../demo-launcher/) from a local `repo-setup-scripts` checkout, so every Copilot session (including a blank new chat) can open it. It's the same file that [`install.sh`](../demo-launcher/install.sh) writes.

## Which install to use

- **Booth machines:** use the install scripts, not this URL. machine-setup's `setup.sh` / `install-demo-launcher.sh` (macOS and Linux, which run `install.sh`) and `setup.ps1` / `install-demo-launcher.ps1` (Windows) clone `~/repos/repo-setup-scripts` and write the loader in one step during machine setup. To repair or update it later, re-run `install-demo-launcher.sh` / `install-demo-launcher.ps1` (re-running the full `setup` script skips an existing loader).
- **Everyone else:** install from the URL below. No script to run, and it works on Windows, macOS, and Linux.

Use one or the other on a machine, [not both](#dont-install-both).

## Install from a URL (macOS, Linux, or Windows)

1. Clone the repo to the default path (or anywhere, and set `DEMO_LAUNCHER_REPO` to it). The launcher runs `config.json`, `create-repo`, and `resources/` from this clone:

   ```bash
   gh repo clone octobooth-demos/repo-setup-scripts ~/repos/repo-setup-scripts
   ```

   On Windows that's `%USERPROFILE%\repos\repo-setup-scripts`.

2. In a Copilot app chat, ask:

   > Install the extension from https://github.com/octobooth-demos/repo-setup-scripts/tree/main/.github/extensions/demo-launcher-loader

   It installs to `~/.copilot/extensions/demo-launcher-loader/`.

3. Restart the Copilot app, then ask Copilot to "open the demo launcher" in any chat.

To remove it, remove `demo-launcher-loader` from the app's Extensions screen.

## Don't install both

A URL install is named after this folder, `demo-launcher-loader`, even if you ask for the name `demo-launcher` (verified on Windows). The scripts install to `demo-launcher`. So a URL install doesn't replace the script's loader, and with both you get two "Demo Launcher" canvases labeled **Personal**. The app's Extensions screen shows the folder names.

To fix it, remove one and restart the app. On booth machines, keep the script's: remove `demo-launcher-loader` from the Extensions screen (or delete `~/.copilot/extensions/demo-launcher-loader`), then re-run `install-demo-launcher.sh` / `install-demo-launcher.ps1`.

A **repository: repo-setup-scripts** "Demo Launcher" is fine; that's the project's copy if you added the repo as a project. See [Two Demo Launcher canvases](../../../README.md#two-demo-launcher-canvases).

## How it finds the checkout

1. `DEMO_LAUNCHER_REPO`, if set.
2. The checkout `install.sh` ran from (baked into the `INSTALLED_REPO` line; empty for URL installs).
3. `~/repos/repo-setup-scripts` (`%USERPROFILE%\repos\repo-setup-scripts` on Windows).

It imports `.github/extensions/demo-launcher/extension.mjs` from there, so `git pull` updates the launcher; you don't need to reinstall. If the checkout is missing, the loader still registers a **Demo Launcher** canvas that says where to clone the repo.

In a session inside a repo that ships its own Demo Launcher (this repo or a fork), the loader does nothing and lets that copy provide the canvas.
