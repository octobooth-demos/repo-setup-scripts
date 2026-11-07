# Security Supply Chain (v4) demo: presenter notes

This file is for presenters only. It stays in `repo-setup-scripts` and is never copied into demo repos. The planted vulnerabilities are intentional; don't fix them here.

## Create it ahead: about 10 minutes

Create this demo before the booth opens, once, on one machine signed in as a booth account, then bookmark the repo in the browser. Open the same repo URL on the other booth machines and bookmark it there too; there's no need to create it on every machine. It takes about 10 minutes:

1. **CodeQL default setup** takes about 5 minutes for GitHub to apply to JavaScript/TypeScript. Then the script opens the two demo PRs.
2. **AI findings** on the PHP PR appear about 3–4 minutes after the script's automatic trigger commit (`chore: trigger AI code scanning`). No manual push is needed. If there are none after about 10 minutes, push any small commit to `feature/supplier-notes`.

The nightly cleanup deletes `demo-generated` org repos once they're more than 72 hours old, so create it within 72 hours of when you'll use it (the morning of, or the day before). One repo serves the whole day.

### Checklist

1. **Security → Dependabot** lists alerts, and Dependabot's fix PRs are open.
2. **"Demo: Preventing Vulnerabilities in TypeScript"** shows CodeQL alerts and a Copilot Autofix suggestion.
3. **"Demo: Preventing Vulnerabilities in PHP"** shows findings labeled **AI**.

## Where to show each finding

### Dependabot

**Security → Dependabot** for the alerts, then open one of Dependabot's PRs to show the version bump it proposes.

### TypeScript PR (`feature-add-tos-download`): CodeQL + Copilot Autofix

- **Conversation:** the CodeQL alerts, including the path traversal in `api/src/routes/legal.ts` (`file` and `lang` query parameters joined into a path), with the **Copilot Autofix** suggestion.
- **Files changed:** the same alerts inline, plus the code-quality findings in `api/src/repositories/userDetailsRepo.ts`.

### PHP PR (`feature/supplier-notes`): AI findings

- **Conversation:** findings labeled **AI**, posted by **github-advanced-security**. CodeQL doesn't analyze PHP; these come from AI Code Scanning.
- **Files changed:** pick **All commits** in the commit dropdown. The latest commit is the empty trigger commit, so a single-commit view shows no code and no findings.
- AI findings live only on the PR. They don't appear in **Security → Code scanning**.
- AI findings vary from run to run. Read them before visitors arrive and don't promise a specific one. The intended targets are unescaped output (stored XSS) in the note templates (`notes.php`, `note_detail.php`, `dashboard.php`, `note_form.php`) and the reflected search term in `notes.php`.

## Live moment: a fresh AI review

On the PHP PR, open a PHP file from **Files changed** (for example `php/templates/notes.php`), choose **Edit file** (`…` menu), make a small change such as echoing another unescaped value, and commit it to `feature/supplier-notes`. AI Code Scanning reviews the new push and posts findings in a few minutes. Talk through the TypeScript PR while you wait, then come back.
