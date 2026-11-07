# Cutting an event release

An event release is an annotated tag named `booth-YYYY.MM.N` (for example `booth-2026.11.1`) with the **same name on both** this repo and [octobooth-demos/machine-setup](https://github.com/octobooth-demos/machine-setup). Booth machines check it out so every machine runs the same tested version. No tag means booth machines track `main`. See [Event releases](../README.md#event-releases) for how machines use it.

1. **Test current `main` of both repos.** On a booth Mac and a Windows machine, update both checkouts to `main`, restart the Copilot app, and run these from the Demo Launcher: `security-octo-supply-v4`, `ai-security`, and one demo that creates its repo in the booth account (for example `booth-bingo`). Note the commit you tested in each repo (`git rev-parse HEAD`).
2. **Tag both repos with the same name.** In each repo, at the commit you tested:

   ```bash
   git fetch origin
   git tag -a booth-YYYY.MM.N <tested-commit> -m "<event name>"
   git push origin booth-YYYY.MM.N
   ```

   `N` starts at 1 for the first release in a month. Optionally create a GitHub Release from the tag (`gh release create booth-YYYY.MM.N --verify-tag --notes "<event name>"`).
3. **Record the tag in the event's IRL issue**, so whoever sets up the booth machines knows which one to use.
4. **Hotfix during the event:** fix it on `main` with a normal PR, re-test the affected demos on both platforms, then cut the next tag (`booth-YYYY.MM.N+1`) on **both** repos, even if only one changed. Update the IRL issue and move the booth machines to the new tag.

Don't move or delete a tag once booth machines use it; cut a new one instead.

Templates can't be pinned: GitHub always creates repos from a template's default branch. Template changes are guarded by their PR CI, and step 1 is the check that the current templates work right before the event.
