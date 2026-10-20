# Agentic autofix: presenter notes

This file is for presenters only. It stays in `repo-setup-scripts` and is never copied into demo repos.

[Agentic autofix for code scanning alerts](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/autofix-for-code-scanning) became generally available on 2026-10-15. You assign CodeQL alerts on the default branch to Copilot. Copilot fixes them, reruns CodeQL to confirm the fix, and opens a draft PR.

## Before visitors arrive

Setup takes 5–10 minutes because it waits for CodeQL on `main`. After it finishes, give Copilot about 10 more minutes, then check:

1. **The pre-assigned alert** (`js/sql-injection` in `api/src/db/sqlite.ts`) is assigned to Copilot (shown as `github-agentic-autofix`).
2. **Copilot's draft PR** ("Fix code scanning alert(s)…") is open, or Copilot is still working in the repo's **Agents** tab.
3. **Security → Code scanning** lists the remaining open alerts for the live multi-select.

If the setup log says the alert couldn't be assigned (for example, when ChatOps created the demo with an App token), click **Assign to Copilot** on the alert page yourself before visitors arrive.

## Talk track

1. Open **Security → Code scanning**. These are real CodeQL alerts on `main`, from the template and from a "document center" commit.
2. Open the pre-assigned `js/sql-injection` alert and show that it's assigned to Copilot. Open Copilot's draft PR and walk through the fix summary, why it closes the alert, and the validation steps: Copilot reran CodeQL before opening the PR.
3. Go back to the list, select several of the remaining alerts (up to 25), and choose **Assign to Copilot**. Explain that they're fixed together in a single PR. Show the session in the **Agents** tab while it runs.
4. Key points:
   - Agentic autofix works only on alerts on the default branch.
   - Each alert's page now shows **Assign to Copilot** in place of the old **Generate fix** button.
   - It uses AI credits from the Code Security budget and Actions minutes.

## Alerts on `main`

| Source | Expected rule |
| --- | --- |
| Template: `api/src/db/sqlite.ts` | `js/sql-injection` (pre-assigned to Copilot) |
| Template: `.github/workflows/deploy.yml` | `actions/missing-workflow-permissions` |
| Seed: `api/src/routes/supplierPortal.ts` | `js/path-injection`, `js/reflected-xss`, `js/request-forgery`, `js/missing-rate-limiting` |

A typical run has 6 open alerts on `main`. The seed file lives in [`seed/`](seed).
