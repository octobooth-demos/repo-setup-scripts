# AI Scan for pull requests: presenter notes

This file is for presenters only. It stays in `repo-setup-scripts` and is never copied into demo repos.

[AI Scan for pull requests](https://docs.github.com/en/enterprise-cloud@latest/code-security/concepts/code-scanning/ai-powered-security-detections) became generally available on 2026-10-15. It adds AI-based security findings to pull requests in languages CodeQL doesn't cover, such as PHP, Shell/Bash, Terraform (HCL), and Dockerfiles.

## Before visitors arrive

Setup takes 2–4 minutes: AI Scan only reviews PRs opened after code scanning is on, so the script waits for the template's first CodeQL upload before opening the PR. AI Scan usually posts within a few minutes after that, but in testing it once took about 8 minutes. Create the demo well ahead of time, then open the PR ("Containerize the supplier portal and deploy it to staging") and check that findings labeled **AI** appear on the **Conversation** and **Files changed** tabs.

AI findings are nondeterministic: the exact findings, wording, and count vary from run to run (test runs produced 10 and 12). Read them before you present, and don't promise a specific finding. If none appear after about 10 minutes, push any commit to the PR branch to trigger a new scan.

## Talk track

1. Open the PR. Explain that it's an ordinary "infra" PR: a PHP Dockerfile, a deploy script, Terraform, and a PHP health check. CodeQL doesn't analyze any of these languages.
2. On **Conversation**, point out the code scanning findings labeled **AI**. They're advisory: they don't fail the check or block the merge.
3. Open **Files changed** and walk through one or two findings inline. Show the explanation and, if one is offered, the Copilot Autofix suggestion. Mention the 👍/👎 feedback.
4. Key points:
   - No extra workflow, build, or tool to set up. It's on because the org enabled **AI Scan for pull requests**, and the repo inherits that setting.
   - Findings exist only on PRs, never as backlog alerts.
   - It complements CodeQL: CodeQL covers languages like TypeScript, and AI Scan covers the rest.

## What's planted

AI findings vary, so treat this list as the intended targets, not as a guaranteed list of findings.

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

The PR overlay lives in [`pr-infra/`](pr-infra).
