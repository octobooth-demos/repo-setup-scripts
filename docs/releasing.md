# Cutting a release

Releases use semantic version tags, with the **same version on both** this repo and [octobooth-demos/machine-setup](https://github.com/octobooth-demos/machine-setup):

- Each tested release gets a full tag, `vX.Y.Z` (for example `v1.0.0`).
- A moving major tag (`v1`) always points at the latest tested `v1.x.y`, like GitHub Actions' major tags. Booth machines use the major tag. [octobooth-demos/octocat-supply-reusable-workflows](https://github.com/octobooth-demos/octocat-supply-reusable-workflows) uses the same pattern (`@v1`).
- Bump the major (`v2`) only for breaking changes, for example new manual setup steps, changed paths, or new required `gh` scopes. Otherwise bump the minor for new demos or features and the patch for fixes.

See [Releases](../README.md#releases) for how booth machines use the tags.

1. **Test the candidate commits, with machine-setup applied.** The candidate is `main` of both repos, or a `release/vN` branch for a hotfix (step 4). On a booth Mac and a Windows machine:

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

   Optionally create a GitHub Release for it (`gh release create vX.Y.Z --verify-tag --generate-notes`). If the release changes the loader (`.github/extensions/demo-launcher-loader/`) or `install.sh`, say in the notes that booth machines must re-run `install-demo-launcher` after updating.
3. **Move the matching major tag on both repos** to the same recorded commit. Use the release's own major: `vX` for `vX.Y.Z` (`v1` for `v1.4.2`, `v2` for `v2.0.0`). Never move `v1` to a `v2.x.y` commit; a new major gets a new major tag, and machines on `v1` stay there until you move them to `v2`.

   ```bash
   git tag -fa vX <recorded-sha> -m "vX.Y.Z"
   git push origin vX --force
   ```

   Booth machines on `vX` pick it up the next time they update (see [Releases](../README.md#releases)).
4. **Hotfix:** patch the major that booth machines use. If `main` is still on that major, fix it on `main` with a normal PR. If `main` has moved to a newer major, create `release/vN` from the latest tag of that major in **both** repos (`git switch -c release/v1 v1.x.y && git push -u origin release/v1`) and fix it there with a PR into that branch. Machine-setup's `--ref` only accepts tags, so test the candidate by checking out `release/vN` instead of `main` in step 1.2 (in both checkouts) and running the installer without a ref. Then tag the next patch (`vX.Y.Z+1`) on **both** repos, even if only one changed, and move that major's tag.

Never move or delete a full `vX.Y.Z` tag; cut a new one instead. Only the major tag moves.

Templates can't be pinned: GitHub always creates repos from a template's default branch. Template changes are guarded by their PR CI, and step 1 is the check that the current templates work before a release.
