# Releasing

Releases use semantic version tags, with the **same version on both** this repo and [octobooth-demos/machine-setup](https://github.com/octobooth-demos/machine-setup):

- Each tested release gets a full tag, `vX.Y.Z` (for example `v1.0.0`).
- A moving major tag (`v1`) always points at the latest tested `v1.x.y`, like GitHub Actions' major tags. Booth machines use the major tag. [octobooth-demos/octocat-supply-reusable-workflows](https://github.com/octobooth-demos/octocat-supply-reusable-workflows) uses the same pattern (`@v1`).
- Bump the major (`v2`) only for breaking changes, for example new manual setup steps, changed paths, or new required `gh` scopes. Otherwise bump the minor for new demos or features and the patch for fixes.

See [Releases](../README.md#releases) for how booth machines use the tags.

## Making a change

How a change gets from a PR to the booth machines. Booth machines run `v1`, not `main`, so merging never changes them; only moving `v1` does. The commands for steps 4 to 7 are in [Cutting a release](#cutting-a-release).

1. **Open a PR to `main`** in this repo or machine-setup.
2. **Wait for CI and Copilot code review**, and fix what they find.
3. **Merge.** `main` is now ahead of `v1`. Booth machines aren't affected.
4. **Test `main` on a booth Mac and a Windows machine** ([step 1](#cutting-a-release)): clear `BOOTH_RELEASE`, put both checkouts on `main`, run machine-setup's `install-demo-launcher` **without** a ref, run the demos, and record both commit IDs. You can batch several merged PRs into one release.
5. **Tag both repos at the tested commits** ([step 2](#cutting-a-release)), with the same version, even if only one repo changed, so the versions stay paired. Bump the patch (`v1.0.x`) for fixes and the minor (`v1.x.0`) for new demos or features.
6. **Move `v1`** to the same commits ([step 3](#cutting-a-release)).
7. **Create the GitHub Releases** on both repos with `--generate-notes --verify-tag` ([step 4](#cutting-a-release)).
8. **Update the booth machines:** fetch and check out `v1` in machine-setup, run `install-demo-launcher --ref v1` (`-Ref v1` on Windows), and restart the Copilot app. See [Update a booth machine](../README.md#update-a-booth-machine).

Steps 5 to 7 in one block, run from clones where you can push to both repos (not necessarily the booth machine). Fill in the version and the two commit IDs you recorded in step 4:

```bash
VERSION=v1.0.1                 # the new version
MAJOR=v1                       # its major: v1 for any v1.x.y
BRANCH=main                    # or release/vN for a hotfix on an older major
MS=~/repos/machine-setup       # your clone of machine-setup
RSS=~/repos/repo-setup-scripts # your clone of repo-setup-scripts
MS_SHA=PASTE_MACHINE_SETUP_SHA     # recorded in step 4
RSS_SHA=PASTE_REPO_SETUP_SCRIPTS_SHA # recorded in step 4

git -C "$MS" fetch origin --tags --force &&
git -C "$RSS" fetch origin --tags --force &&
git -C "$MS" merge-base --is-ancestor "$MS_SHA" "origin/$BRANCH" &&
git -C "$RSS" merge-base --is-ancestor "$RSS_SHA" "origin/$BRANCH" &&
git -C "$MS" tag -a "$VERSION" "$MS_SHA" -m "$VERSION" &&
git -C "$RSS" tag -a "$VERSION" "$RSS_SHA" -m "$VERSION" &&
git -C "$MS" tag -fa "$MAJOR" "$MS_SHA" -m "$MAJOR -> $VERSION" &&
git -C "$RSS" tag -fa "$MAJOR" "$RSS_SHA" -m "$MAJOR -> $VERSION" &&
git -C "$MS" push origin "$VERSION" &&
git -C "$RSS" push origin "$VERSION" &&
git -C "$MS" push origin "$MAJOR" --force &&
git -C "$RSS" push origin "$MAJOR" --force &&
gh release create "$VERSION" -R octobooth-demos/machine-setup --generate-notes --verify-tag &&
gh release create "$VERSION" -R octobooth-demos/repo-setup-scripts --generate-notes --verify-tag
```

The `merge-base` check stops if a commit isn't on the branch you tested. Nothing is pushed until both repos are checked and tagged locally. If a later step fails, fix it and run the remaining commands; `git tag -a` refuses to overwrite a `vX.Y.Z` tag that already exists. Never move or delete a pushed `vX.Y.Z` tag.

### What booth machines need for each kind of change

| Change | On booth machines |
| --- | --- |
| Demo Launcher, `config.json`, or `create-repo` scripts | Only the `v1` update in step 8. |
| Loader (`.github/extensions/demo-launcher-loader/`) or `install.sh` | The same update. It reinstalls the loader, because `install-demo-launcher` always re-runs `install.sh`. Say so in the release notes, and don't update by hand with `git checkout` alone. |
| machine-setup's `config.json` or `setup` scripts (new apps, extensions, or repos) | The `v1` update, then `setup` again with the same release (`bash setup.sh --ref v1` or `.\setup.ps1 -Ref v1`). See machine-setup's [booth playbook](https://github.com/octobooth-demos/machine-setup/blob/main/docs/booth-playbook.md). |
| A template repo | Nothing, and no release. Templates can't be pinned, so a merged template change reaches every new demo right away, on every machine. Test it in the template repo's PR before merging, then create one demo from it right after merging. |

### When to bump to `v2`

Only for breaking changes: anything a booth machine can't pick up from the `v1` update in step 8, such as new manual setup steps, changed paths, or new required `gh` scopes. Tag `v2.0.0` and create a new `v2` tag; never move `v1` to a `v2.x.y` commit. Machines stay on `v1` until you update each one to `v2` (with `--ref v2`) and do its manual steps, and `v1` can still get hotfixes ([step 5](#cutting-a-release)).

## Cutting a release

1. **Test the candidate commits, with machine-setup applied.** The candidate is `main` of both repos, or a `release/vN` branch for a hotfix (step 5). On a booth Mac and a Windows machine:

   1. Make sure no release is set, so the installer doesn't pin an older tag: `unset BOOTH_RELEASE` (macOS) or `Remove-Item Env:BOOTH_RELEASE -ErrorAction SilentlyContinue` (Windows).
   2. Put both checkouts on the candidate branch and update them:

      ```bash
      git -C ~/repos/machine-setup checkout main && git -C ~/repos/machine-setup pull --ff-only
      git -C ~/repos/repo-setup-scripts checkout main && git -C ~/repos/repo-setup-scripts pull --ff-only
      ```

   3. From `~/repos/machine-setup`, run `install-demo-launcher` **without** `--ref` / `-Ref` (and the full `setup` script if `setup` changed since the last release). Without a release it keeps the branch you checked out, so it installs the loader from the candidate. Updating a checkout alone doesn't apply machine-setup's changes, so don't skip this.
   4. Record both candidate commits:

      ```bash
      git -C ~/repos/machine-setup rev-parse HEAD
      git -C ~/repos/repo-setup-scripts rev-parse HEAD
      ```

   5. Restart the Copilot app and run these from the Demo Launcher: `security-octo-supply-v4`, `ai-security`, and one demo that creates its repo in the booth account (for example `booth-bingo`).
   6. Run the two `rev-parse` commands again. If either changed, or differs between the Mac and Windows machine, start over with the new commits.

2. **Tag the recorded commits, with the same version on both repos.** Tag the exact SHAs from step 1, not whatever the branch points at now:

   ```bash
   git fetch origin --tags --force
   git tag -a vX.Y.Z <recorded-sha> -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

3. **Move the matching major tag on both repos** to the same recorded commit. Use the release's own major: `vX` for `vX.Y.Z` (`v1` for `v1.4.2`, `v2` for `v2.0.0`). Never move `v1` to a `v2.x.y` commit; a new major gets a new major tag, and machines on `v1` stay there until you move them to `v2`.

   ```bash
   git tag -fa vX <recorded-sha> -m "vX.Y.Z"
   git push origin vX --force
   ```

   Booth machines on `vX` pick it up the next time they update (see [Update a booth machine](../README.md#update-a-booth-machine)).
4. **Create the GitHub Release on both repos**, from the pushed tag:

   ```bash
   gh release create vX.Y.Z --generate-notes --verify-tag
   ```

   `--verify-tag` stops if the tag isn't on GitHub, instead of creating it from the default branch. If the release changes the loader (`.github/extensions/demo-launcher-loader/`) or `install.sh`, add `--notes "Booth machines must re-run install-demo-launcher after updating."` (it goes above the generated notes).
5. **Hotfix:** patch the major that booth machines use. If `main` is still on that major, fix it on `main` with a normal PR. If `main` has moved to a newer major, create `release/vN` from the latest tag of that major in **both** repos (`git switch -c release/v1 v1.x.y && git push -u origin release/v1`) and fix it there with a PR into that branch. Machine-setup's `--ref` only accepts tags, so test the candidate by checking out `release/vN` instead of `main` in step 1.2 (in both checkouts) and running the installer without a ref. Then tag the next patch (`vX.Y.Z+1`) on **both** repos, even if only one changed, and move that major's tag. If a newer major exists, create its Release with `--latest=false`.

Never move or delete a full `vX.Y.Z` tag; cut a new one instead. Only the major tag moves.

Templates can't be pinned: GitHub always creates repos from a template's default branch. Template changes are guarded by their PR CI, and step 1 is the check that the current templates work before a release.
