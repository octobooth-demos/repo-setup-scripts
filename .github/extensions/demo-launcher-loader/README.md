# Demo Launcher loader

A small user-level Copilot extension that loads the [Demo Launcher](../demo-launcher/) from a local `repo-setup-scripts` checkout, so every Copilot session (including a blank new chat) can open it. It's the same file that [`install.sh`](../demo-launcher/install.sh) writes, so either install method gives you the same loader.

## Install from a URL (macOS, Linux, or Windows)

1. Clone the repo to the default path (or anywhere, and set `DEMO_LAUNCHER_REPO` to it):

   ```bash
   gh repo clone octobooth-demos/repo-setup-scripts ~/repos/repo-setup-scripts
   ```

   On Windows that's `%USERPROFILE%\repos\repo-setup-scripts`.

2. In a Copilot app chat, ask Copilot to install the extension **with the name `demo-launcher`**:

   > Install the extension from https://github.com/octobooth-demos/repo-setup-scripts/tree/main/.github/extensions/demo-launcher-loader with the name demo-launcher

   The name matters: it installs to `~/.copilot/extensions/demo-launcher/`, the same folder `install.sh` uses, so it replaces that loader instead of adding a second Demo Launcher.

3. Restart the Copilot app, then ask Copilot to "open the demo launcher" in any chat.

## How it finds the checkout

1. `DEMO_LAUNCHER_REPO`, if set.
2. The checkout `install.sh` ran from (baked into the `INSTALLED_REPO` line; empty for URL installs).
3. `~/repos/repo-setup-scripts` (`%USERPROFILE%\repos\repo-setup-scripts` on Windows).

It imports `.github/extensions/demo-launcher/extension.mjs` from there, so `git pull` updates the launcher; you don't need to reinstall. If the checkout is missing, the loader still registers a **Demo Launcher** canvas that says where to clone the repo.

In a session inside a repo that ships its own Demo Launcher (this repo or a fork), the loader does nothing and lets that copy provide the canvas. On staff builds that list canvases outside a session, you may still see two Demo Launchers if the repo is also added as a project; either one works.
