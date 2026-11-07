# Cutting a release

Releases use semantic version tags, with the **same version on both** this repo and [octobooth-demos/machine-setup](https://github.com/octobooth-demos/machine-setup):

- Each tested release gets a full tag, `vX.Y.Z` (for example `v1.0.0`).
- A moving major tag (`v1`) always points at the latest tested `v1.x.y`, like GitHub Actions' major tags. Booth machines use the major tag. [octobooth-demos/octocat-supply-reusable-workflows](https://github.com/octobooth-demos/octocat-supply-reusable-workflows) uses the same pattern (`@v1`).
- Bump the major (`v2`) only for breaking changes, for example new manual setup steps, changed paths, or new required `gh` scopes. Otherwise bump the minor for new demos or features and the patch for fixes.

See [Releases](../README.md#releases) for how booth machines use the tags.

1. **Test current `main` of both repos.** On a booth Mac and a Windows machine, update both checkouts to `main`, restart the Copilot app, and run these from the Demo Launcher: `security-octo-supply-v4`, `ai-security`, and one demo that creates its repo in the booth account (for example `booth-bingo`). Note the commit you tested in each repo (`git rev-parse HEAD`).
2. **Tag both repos with the same version.** In each repo, at the commit you tested:

   ```bash
   git fetch origin --tags --force
   git tag -a vX.Y.Z <tested-commit> -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

   Optionally create a GitHub Release for it (`gh release create vX.Y.Z --verify-tag --generate-notes`).
3. **Move the major tag on both repos** to the new version:

   ```bash
   git tag -fa v1 vX.Y.Z^{} -m "vX.Y.Z"
   git push origin v1 --force
   ```

   Booth machines on `v1` pick it up the next time they update (see [Releases](../README.md#releases)).
4. **Hotfix:** fix it on `main` with a normal PR, re-test the affected demos on both platforms, then tag the next patch (`vX.Y.Z+1`) on **both** repos, even if only one changed, and move `v1` again.

Never move or delete a full `vX.Y.Z` tag; cut a new one instead. Only the major tag moves.

Templates can't be pinned: GitHub always creates repos from a template's default branch. Template changes are guarded by their PR CI, and step 1 is the check that the current templates work before a release.
