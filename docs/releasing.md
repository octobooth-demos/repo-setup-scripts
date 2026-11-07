# Cutting a release

Releases use semantic version tags, with the **same version on both** this repo and [octobooth-demos/machine-setup](https://github.com/octobooth-demos/machine-setup):

- Each tested release gets a full tag, `vX.Y.Z` (for example `v1.0.0`).
- A moving major tag (`v1`) always points at the latest tested `v1.x.y`, like GitHub Actions' major tags. Booth machines use the major tag. [octobooth-demos/octocat-supply-reusable-workflows](https://github.com/octobooth-demos/octocat-supply-reusable-workflows) uses the same pattern (`@v1`).
- Bump the major (`v2`) only for breaking changes, for example new manual setup steps, changed paths, or new required `gh` scopes. Otherwise bump the minor for new demos or features and the patch for fixes.

See [Releases](../README.md#releases) for how booth machines use the tags.

1. **Test the exact commits you'll tag, with machine-setup applied.** On a booth Mac and a Windows machine, check out the candidate commit (current `main`) of both repos. Then re-run machine-setup from that checkout so its changes and the loader are actually installed: `install-demo-launcher` at minimum, and the full `setup` script if `setup` changed since the last release. Restart the Copilot app and run these from the Demo Launcher: `security-octo-supply-v4`, `ai-security`, and one demo that creates its repo in the booth account (for example `booth-bingo`). Note the commit you tested in each repo (`git rev-parse HEAD`). Updating a checkout alone doesn't apply machine-setup's changes, so don't skip the re-run.
2. **Tag both repos with the same version.** In each repo, at the commit you tested:

   ```bash
   git fetch origin --tags --force
   git tag -a vX.Y.Z <tested-commit> -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

   Optionally create a GitHub Release for it (`gh release create vX.Y.Z --verify-tag --generate-notes`). If the release changes the loader (`.github/extensions/demo-launcher-loader/`) or `install.sh`, say in the notes that booth machines must re-run `install-demo-launcher` after updating.
3. **Move the matching major tag on both repos** to the new version. Use the release's own major: `vX` for `vX.Y.Z` (`v1` for `v1.4.2`, `v2` for `v2.0.0`). Never move `v1` to a `v2.x.y` commit; a new major gets a new major tag, and machines on `v1` stay there until you move them to `v2`.

   ```bash
   git tag -fa vX vX.Y.Z^{} -m "vX.Y.Z"
   git push origin vX --force
   ```

   Booth machines on `vX` pick it up the next time they update (see [Releases](../README.md#releases)).
4. **Hotfix:** patch the major that booth machines use. If `main` is still on that major, fix it on `main` with a normal PR. If `main` has moved to a newer major, branch from the latest tag of the major you're patching (`git switch -c release/v1 v1.x.y`), fix it there, and tag from that branch. Re-test as in step 1 on both platforms, then tag the next patch (`vX.Y.Z+1`) on **both** repos, even if only one changed, and move that major's tag (`vX`) again.

Never move or delete a full `vX.Y.Z` tag; cut a new one instead. Only the major tag moves.

Templates can't be pinned: GitHub always creates repos from a template's default branch. Template changes are guarded by their PR CI, and step 1 is the check that the current templates work before a release.
