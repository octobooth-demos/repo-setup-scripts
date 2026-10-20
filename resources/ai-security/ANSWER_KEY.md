# AI Security demo: presenter notes

This file is for presenters only. It stays in `repo-setup-scripts` and is never copied into demo repos.

The demo covers two features that became generally available on 2026-10-15:

- [AI Scan for pull requests](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/ai-powered-security-detections): AI-based findings on PRs for languages CodeQL doesn't cover, such as PHP, Shell/Bash, Terraform (HCL), and Dockerfiles.
- [Agentic autofix for code scanning alerts](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/autofix-for-code-scanning): assign default-branch CodeQL alerts to Copilot. Copilot fixes them, reruns CodeQL to confirm the fix, and opens a draft PR.

## Before visitors arrive

Setup takes 5–10 minutes because it waits for CodeQL on `main`. After it finishes, give it about 10 more minutes, then check:

1. **The AI Scan PR** ("Containerize the supplier portal and deploy it to staging") shows code scanning findings labeled **AI** on the **Conversation** and **Files changed** tabs. AI findings are nondeterministic, so the exact findings, wording, and count vary from run to run. Read them before you present, and don't promise a specific finding.
2. **The pre-assigned alert** (`js/sql-injection` in `api/src/db/sqlite.ts`) shows Copilot as the assignee. A **draft PR from Copilot** is open, or Copilot is still working in the repo's **Agents** tab.
3. **Security → Code scanning** lists the remaining open alerts for the live multi-select.

If the setup log says the alert couldn't be assigned (for example, when ChatOps created the demo with an App token), assign it yourself from the alert page before visitors arrive.

## Talk track

### 1. AI Scan on a pull request

1. Open the PR. Explain that it's an ordinary "infra" PR: a PHP Dockerfile, a deploy script, Terraform, and a PHP health check. CodeQL doesn't analyze any of these languages.
2. On **Conversation**, point out the code scanning findings labeled **AI** next to the normal CodeQL check. They're advisory: they don't fail the check or block the merge.
3. Open **Files changed** and walk through one or two findings inline. Show the explanation and, if one is offered, the Copilot Autofix suggestion. Mention the 👍/👎 feedback.
4. Key points:
   - No extra workflow, build, or tool. It's on because the org enabled **AI Scan for pull requests**, and the repo inherits that setting.
   - Findings exist only on PRs, never as backlog alerts.
   - It complements CodeQL: CodeQL handles TypeScript and Actions, and AI Scan covers the rest.

### 2. Agentic autofix for code scanning alerts

1. Open **Security → Code scanning**. These are real CodeQL alerts on `main`, from the template and from a "document center" commit.
2. Open the pre-assigned `js/sql-injection` alert and show that it's assigned to Copilot. Open Copilot's draft PR and walk through the fix summary, why it closes the alert, and the validation steps: Copilot reran CodeQL before opening the PR.
3. Go back to the list, select several of the remaining alerts (up to 25), and choose **Assign to Copilot**. Explain that they're fixed together in a single PR. Show the session in the **Agents** tab while it runs.
4. Key points:
   - Agentic autofix works only on alerts on the default branch.
   - Each alert's page now shows **Assign to Copilot** in place of the old **Generate fix** button.
   - It uses AI credits from the Code Security budget and Actions minutes.

## What's planted

AI findings vary, so treat this list as the intended targets, not as a guaranteed list of findings.

### AI Scan PR (`feature/containerize-supplier-portal`)

| File | Planted issue | AI Scan category |
| --- | --- | --- |
| `php/Dockerfile` | Unpinned `php:apache` base image | Supply chain |
| `php/Dockerfile` | `curl http://… \| bash` with no integrity check, over HTTP | Supply chain / data integrity |
| `php/Dockerfile` | Token baked into `ENV`; `display_errors=On`, `expose_php=On`; `chmod -R 777`; runs as root | Sensitive data exposure / misconfiguration |
| `scripts/deploy-staging.sh` | Registry password echoed to logs | Sensitive data exposure |
| `scripts/deploy-staging.sh` | Unquoted `$TAG` / `$EXTRA_FLAGS` in a remote `ssh` command and `eval` | String (shell) injection |
| `scripts/deploy-staging.sh` | `curl -k` and `StrictHostKeyChecking=no` | Authentication failures |
| `infra/terraform/main.tf` | Hard-coded AWS access keys (AWS documentation example values) | Sensitive data exposure |
| `infra/terraform/main.tf` | SSH and all TCP ports open to `0.0.0.0/0` | Security misconfiguration |
| `infra/terraform/main.tf` | Unencrypted root volume; IMDSv1 allowed (`http_tokens = "optional"`) | Weak crypto / misconfiguration |
| `infra/terraform/main.tf` | Public-read S3 bucket with public access block disabled | Broken access control |
| `php/public/healthz.php` | `$_GET['volume']` concatenated into `shell_exec` | String (command) injection |
| `php/public/healthz.php` | `?debug` dumps every environment variable | Sensitive data exposure |

### CodeQL alerts on `main` (agentic autofix)

| Source | Expected rule |
| --- | --- |
| Template: `api/src/db/sqlite.ts` | `js/sql-injection` (pre-assigned to Copilot) |
| Template: `.github/workflows/deploy.yml` | `actions/missing-workflow-permissions` |
| Seed: `api/src/routes/supplierPortal.ts` | `js/path-injection`, `js/reflected-xss`, `js/request-forgery`, `js/missing-rate-limiting` |

A typical run has 6 open alerts on `main`.

The seed files live in [`seed/`](seed). The PR overlay lives in [`pr-infra/`](pr-infra).
