#!/bin/bash

# Consolidated script to create GitHub repos from various templates
# with different workflows based on the selected template.
#
# All repo/org metadata lives in config.json next to this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
DEMO_TOPIC="demo-generated"
PAGES_WORKFLOW="pages.yml"
AI_SCAN_API_VERSION="2026-03-10"
# The UI's "Assign to Copilot" uses github-agentic-autofix[bot]; the GA changelog names
# copilot-swe-agent[bot], so it's kept as a fallback.
COPILOT_AUTOFIX_ASSIGNEES=("github-agentic-autofix[bot]" "copilot-swe-agent[bot]")
CODEQL_WAIT_SECONDS="${CODEQL_WAIT_SECONDS:-900}"

# --- Arguments ---

usage() {
    cat <<'EOF'
Usage: create-repo.sh [--template <key>] [--owner <name>] [--no-clone | --serve]
       create-repo.sh --cleanup [--owner <name>] [--older-than <hours> | --all] [--dry-run] [--yes]

  (no args)            Interactive: pick a template from a menu.
  --template <key>     Non-interactive: use the config.json repo entry with this key.
                       Never prompts and never starts `gh auth login`.
  --owner <name>       Account or org to create the repo in. Default: the template's
                       "owner" in config.json, otherwise the logged-in account.
  --no-clone           Skip the permanent clone into ~/repos (useful in CI).
  --serve              After setup, check out the default branch and serve it on
                       http://localhost:8080 (npm start). Needs Node.js.
  --cleanup            Delete repos with the demo-generated topic owned by --owner
                       (default: the logged-in account) that are older than --older-than.
  --older-than <hours> Age cutoff for --cleanup (default: 24).
  --all                With --cleanup, ignore the age cutoff and delete every demo repo
                       (end of event). Same as --older-than 0, with a warning.
  --dry-run            With --cleanup, list what would be deleted.
  --yes                With --cleanup, skip the confirmation prompt.
  -h, --help           Show this help.
EOF
}

require_value() {
    if [ -z "${2:-}" ]; then
        echo "❌ $1 requires a value"
        usage
        exit 2
    fi
}

TEMPLATE_KEY=""
NON_INTERACTIVE=false
NO_CLONE=false
OWNER_OVERRIDE=""
SERVE=false
CLEANUP=false
OLDER_THAN_HOURS=24
OLDER_THAN_SET=false
ALL=false
DRY_RUN=false
ASSUME_YES=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --owner)
            require_value "$1" "${2:-}"
            OWNER_OVERRIDE="$2"
            shift 2
            ;;
        --serve)
            SERVE=true
            shift
            ;;
        --cleanup)
            CLEANUP=true
            shift
            ;;
        --older-than)
            require_value "$1" "${2:-}"
            OLDER_THAN_HOURS="$2"
            OLDER_THAN_SET=true
            shift 2
            ;;
        --all)
            ALL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --yes)
            ASSUME_YES=true
            shift
            ;;
        --template)
            if [ -z "${2:-}" ]; then
                echo "❌ --template requires a template key"
                usage
                exit 2
            fi
            TEMPLATE_KEY="$2"
            NON_INTERACTIVE=true
            shift 2
            ;;
        --template=*)
            TEMPLATE_KEY="${1#*=}"
            if [ -z "$TEMPLATE_KEY" ]; then
                echo "❌ --template requires a template key"
                usage
                exit 2
            fi
            NON_INTERACTIVE=true
            shift
            ;;
        --no-clone)
            NO_CLONE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "❌ Unknown argument: $1"
            usage
            exit 2
            ;;
    esac
done

if [ "$CLEANUP" = true ] && { [ -n "$TEMPLATE_KEY" ] || [ "$SERVE" = true ] || [ "$NO_CLONE" = true ]; }; then
    echo "❌ --cleanup cannot be combined with --template, --serve, or --no-clone"
    exit 2
fi
if [ "$CLEANUP" = false ] && { [ "$DRY_RUN" = true ] || [ "$ASSUME_YES" = true ] || [ "$ALL" = true ]; }; then
    echo "❌ --dry-run, --yes, and --all only apply to --cleanup"
    exit 2
fi
if [ "$ALL" = true ] && [ "$OLDER_THAN_SET" = true ]; then
    echo "❌ --all cannot be combined with --older-than"
    exit 2
fi
[ "$ALL" = true ] && OLDER_THAN_HOURS=0
if ! [[ "$OLDER_THAN_HOURS" =~ ^[0-9]+$ ]]; then
    echo "❌ --older-than must be a whole number of hours"
    exit 2
fi
if [ "$SERVE" = true ] && [ "$NO_CLONE" = true ]; then
    echo "❌ --serve needs the local clone, so it cannot be combined with --no-clone"
    exit 2
fi

# --- Helper functions ---

TEMP_DIR=""

cleanup_temp() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        cd /
        rm -rf "$TEMP_DIR"
        TEMP_DIR=""
    fi
}

trap cleanup_temp EXIT

# Read a value from config.json. Empty string if missing/null.
# Usage: cfg <jq filter>
cfg() {
    jq -r "$1 // empty" "$CONFIG_FILE"
}

# Read a per-repo value from the selected entry by index.
# Usage: repo_cfg <jq filter against the repo object>
repo_cfg() {
    jq -r ".repos[$SELECTED_INDEX] | $1 // empty" "$CONFIG_FILE"
}

clone_to_temp() {
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    gh repo clone "$FULL_REPO_NAME" "$REPO_NAME" -- --quiet
    cd "$REPO_NAME"
    ensure_git_identity
}

# Fresh booth machines often have no git identity; fall back to the GitHub account's noreply address.
ensure_git_identity() {
    if [ -n "$(git config user.email || true)" ]; then
        return
    fi
    local user_id
    user_id=$(gh api user --jq '.id' 2>/dev/null) || user_id=""
    local email="${CURRENT_USER}@users.noreply.github.com"
    [ -n "$user_id" ] && email="${user_id}+${CURRENT_USER}@users.noreply.github.com"
    echo "ℹ️  No git identity configured; committing as $CURRENT_USER <$email> in this clone only"
    git config user.name "$CURRENT_USER"
    git config user.email "$email"
}

# Start a codespace for the current repo.
# Usage: start_codespace [branch]
start_codespace() {
    local branch="$1"
    local machine_args=""
    if [ -n "$CODESPACE_MACHINE" ]; then
        machine_args="--machine $CODESPACE_MACHINE"
    fi
    local branch_args=""
    if [ -n "$branch" ]; then
        branch_args="--branch $branch"
    fi

    echo "☁️  Starting codespace..."
    gh codespace create \
        --repo "$FULL_REPO_NAME" \
        $machine_args \
        $branch_args
    echo "✅ Codespace created successfully!"
}

# Create a PR branch from a local resource directory.
# Usage: create_pr_from_resources <branch> <resource_dir> <body_file> <commit_msg> <pr_title> [base_branch]
#   resource_dir and body_file are paths relative to SCRIPT_DIR.
#   body_file must live inside resource_dir; it is removed from the working
#   tree after copy so it isn't committed into the demo branch.
#   base_branch defaults to the repo's default branch; the new branch is cut
#   from it locally and the PR targets it.
# Sets CREATED_PR_NUMBER and CREATED_PR_URL.
create_pr_from_resources() {
    local branch_name="$1"
    local resource_dir="$2"
    local body_file="$3"
    local commit_msg="$4"
    local pr_title="$5"
    local base_branch="${6:-$DEFAULT_BRANCH}"

    local abs_resource_dir="$SCRIPT_DIR/$resource_dir"
    local abs_body_file="$SCRIPT_DIR/$body_file"
    local rel_body_file="${body_file#"$resource_dir"/}"

    echo "📝 Creating PR: $pr_title (base: $base_branch)..."
    git checkout --quiet -b "$branch_name" "$base_branch"
    # "/." copies the directory's contents on both BSD (macOS) and GNU cp.
    cp -R "$abs_resource_dir"/. .
    # Don't commit the PR body file.
    rm -f "$rel_body_file"
    git add -A
    git commit -m "$commit_msg" --quiet
    git push -u origin "$branch_name" --quiet 2>/dev/null

    CREATED_PR_URL=$(gh pr create \
        --repo "$FULL_REPO_NAME" \
        --head "$branch_name" \
        --base "$base_branch" \
        --title "$pr_title" \
        --body-file "$abs_body_file")
    CREATED_PR_NUMBER="${CREATED_PR_URL##*/}"
    if ! [[ "$CREATED_PR_NUMBER" =~ ^[0-9]+$ ]]; then
        echo "❌ Could not determine PR number from: $CREATED_PR_URL"
        exit 1
    fi

    echo "✅ PR #$CREATED_PR_NUMBER created: $CREATED_PR_URL"
}

# Request a Copilot Code Review on a PR. Never fails the setup: older gh
# versions don't know "@copilot", and some tokens (e.g. GitHub App installation
# tokens) can't request it, so fall back to the REST API and finally just warn.
# Usage: request_copilot_review <pr_number>
request_copilot_review() {
    local pr_number="$1"
    if gh pr edit "$pr_number" --repo "$FULL_REPO_NAME" --add-reviewer "@copilot" > /dev/null 2>&1; then
        echo "🤖 Copilot Code Review requested on PR #$pr_number"
        return 0
    fi
    if gh api --method POST "repos/$FULL_REPO_NAME/pulls/$pr_number/requested_reviewers" \
        -f "reviewers[]=copilot-pull-request-reviewer[bot]" --silent > /dev/null 2>&1; then
        echo "🤖 Copilot Code Review requested on PR #$pr_number (via REST API)"
        return 0
    fi
    echo "⚠️  Could not request Copilot Code Review on PR #$pr_number."
    echo "   Open the PR and pick Copilot under Reviewers to request it manually."
    return 0
}

# Validate a list of PR entries (prs[] or stack[]) on the selected repo.
# Usage: validate_pr_entries <field> <min_count>
# Appends missing fields to the caller's `missing` array; exits on bad paths.
validate_pr_entries() {
    local field="$1"
    local min_count="$2"
    local count
    count=$(jq ".repos[$SELECTED_INDEX].$field | length // 0" "$CONFIG_FILE")
    if [ "$count" -eq 0 ]; then
        missing+=("${field}[]")
        return
    fi
    if [ "$count" -lt "$min_count" ]; then
        echo "❌ ${field}[] needs at least $min_count entries (found $count)"
        exit 1
    fi
    local i=0
    while [ "$i" -lt "$count" ]; do
        local branch resource_dir body commit title
        branch=$(jq -r ".repos[$SELECTED_INDEX].${field}[$i].branch // empty" "$CONFIG_FILE")
        resource_dir=$(jq -r ".repos[$SELECTED_INDEX].${field}[$i].resource_dir // empty" "$CONFIG_FILE")
        body=$(jq -r ".repos[$SELECTED_INDEX].${field}[$i].body_file // empty" "$CONFIG_FILE")
        commit=$(jq -r ".repos[$SELECTED_INDEX].${field}[$i].commit_message // empty" "$CONFIG_FILE")
        title=$(jq -r ".repos[$SELECTED_INDEX].${field}[$i].title // empty" "$CONFIG_FILE")
        [ -z "$branch" ] && missing+=("${field}[$i].branch")
        [ -z "$resource_dir" ] && missing+=("${field}[$i].resource_dir")
        [ -z "$body" ] && missing+=("${field}[$i].body_file")
        [ -z "$commit" ] && missing+=("${field}[$i].commit_message")
        [ -z "$title" ] && missing+=("${field}[$i].title")
        if [ -n "$resource_dir" ] && [ ! -d "$SCRIPT_DIR/$resource_dir" ]; then
            echo "❌ ${field}[$i].resource_dir not found: $SCRIPT_DIR/$resource_dir"
            exit 1
        fi
        if [ -n "$body" ] && [ ! -f "$SCRIPT_DIR/$body" ]; then
            echo "❌ ${field}[$i].body_file not found: $SCRIPT_DIR/$body"
            exit 1
        fi
        if [ -n "$resource_dir" ] && [ -n "$body" ] && [[ "$body" != "$resource_dir"/* ]]; then
            echo "❌ ${field}[$i].body_file must be inside resource_dir"
            exit 1
        fi
        i=$((i + 1))
    done
}

# Cleanup only ever deletes repos carrying $DEMO_TOPIC, so an untagged demo repo
# would never be cleaned up. Retry, then delete the new repo rather than leave it.
tag_demo_repo() {
    local attempt
    for attempt in 1 2 3; do
        if gh repo edit "$FULL_REPO_NAME" --add-topic "$DEMO_TOPIC" > /dev/null; then
            echo "🏷️  Added topic: $DEMO_TOPIC"
            return 0
        fi
        [ "$attempt" -lt 3 ] && sleep 2
    done
    echo "❌ Could not add the '$DEMO_TOPIC' topic to $FULL_REPO_NAME, so cleanup would never find it."
    if gh repo delete "$FULL_REPO_NAME" --yes; then
        echo "🗑️  Deleted the untagged repo $FULL_REPO_NAME. Run the script again."
    else
        echo "   Could not delete it either. Tag or delete it by hand:"
        echo "   gh repo edit $FULL_REPO_NAME --add-topic $DEMO_TOPIC"
        echo "   gh repo delete $FULL_REPO_NAME --yes"
    fi
    exit 1
}

# Wait (bounded) until a repo generated from a template has its default branch.
# Sets DEFAULT_BRANCH.
wait_for_repo_ready() {
    local attempt=1
    local max_attempts=60
    echo "⏳ Waiting for template to be fully processed..."
    while [ "$attempt" -le "$max_attempts" ]; do
        DEFAULT_BRANCH=$(gh api "repos/$FULL_REPO_NAME" --jq '.default_branch' 2>/dev/null || true)
        if [ -n "$DEFAULT_BRANCH" ] && gh api "repos/$FULL_REPO_NAME/branches/$DEFAULT_BRANCH" --silent 2>/dev/null; then
            return 0
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    echo "❌ Repository $FULL_REPO_NAME was not ready after $max_attempts attempts"
    exit 1
}

# Register STACK_PR_NUMBERS (bottom to top) as a native stack and verify it.
register_stack() {
    local args=()
    local n
    for n in "${STACK_PR_NUMBERS[@]}"; do
        args+=(-F "pull_requests[]=$n")
    done

    echo "🥞 Registering native stack: ${STACK_PR_NUMBERS[*]} (bottom to top)..."
    if ! gh api --method POST "repos/$FULL_REPO_NAME/stacks" "${args[@]}" --silent; then
        echo "❌ Failed to register the native stack via the Stacks API."
        echo "   The dependent PR chain still exists (each PR targets the one below it):"
        for n in "${STACK_PR_NUMBERS[@]}"; do
            echo "   https://github.com/$FULL_REPO_NAME/pull/$n"
        done
        exit 1
    fi

    local expected="${STACK_PR_NUMBERS[*]}"
    local actual=""
    local attempt=1
    while [ "$attempt" -le 5 ]; do
        actual=$(gh api "repos/$FULL_REPO_NAME/stacks?pull_request=${STACK_PR_NUMBERS[0]}" \
            --jq '[.[0].pull_requests[]?.number | tostring] | join(" ")' 2>/dev/null || true)
        [ "$actual" = "$expected" ] && break
        sleep 2
        attempt=$((attempt + 1))
    done
    if [ "$actual" != "$expected" ]; then
        echo "❌ Stack verification failed: expected [$expected], got [$actual]"
        exit 1
    fi
    echo "✅ Native stack registered and verified: $actual"
}

# Turn on AI Scan for pull requests. Org-owned repos inherit the org setting, so
# this is usually a no-op; it only warns because the org may enforce the value.
enable_ai_scan() {
    echo "🤖 Enabling AI Scan for pull requests..."
    if gh api --method PATCH "repos/$FULL_REPO_NAME/code-scanning/ai-scan" \
        -H "X-GitHub-Api-Version: $AI_SCAN_API_VERSION" -f pr_scan=enabled --silent 2>/dev/null; then
        echo "✅ AI Scan for pull requests enabled"
        return 0
    fi
    local state
    state=$(gh api "repos/$FULL_REPO_NAME/code-scanning/ai-scan" \
        -H "X-GitHub-Api-Version: $AI_SCAN_API_VERSION" --jq '.pr_scan' 2>/dev/null || true)
    if [ "$state" = "enabled" ]; then
        echo "✅ AI Scan for pull requests already enabled (inherited from the organization)"
        return 0
    fi
    echo "⚠️  Could not enable AI Scan for pull requests (current state: ${state:-unknown})."
    echo "   An org owner must allow it under Settings → Code security → Global settings → AI Scan."
}

# Wait (bounded) for the CodeQL workflow run on <sha> to finish and for open
# default-branch alerts to show up. Exits with a clear message on failure.
# Usage: wait_for_codeql <sha>
wait_for_codeql() {
    local sha="$1"
    local waited=0
    local run_id="" state=""
    echo "⏳ Waiting for CodeQL ($CODEQL_WORKFLOW) to analyze $DEFAULT_BRANCH (usually 3-6 minutes)..."
    while [ "$waited" -lt "$CODEQL_WAIT_SECONDS" ]; do
        if [ -z "$run_id" ]; then
            run_id=$(gh run list --repo "$FULL_REPO_NAME" --workflow "$CODEQL_WORKFLOW" --commit "$sha" \
                --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)
        fi
        if [ -n "$run_id" ]; then
            state=$(gh run view "$run_id" --repo "$FULL_REPO_NAME" --json status,conclusion \
                --jq '"\(.status) \(.conclusion)"' 2>/dev/null || true)
            case "$state" in
                "completed success") break ;;
                completed\ *)
                    echo "❌ CodeQL finished with '${state#completed }' on $DEFAULT_BRANCH."
                    echo "   See https://github.com/$FULL_REPO_NAME/actions/runs/$run_id"
                    exit 1
                    ;;
            esac
        fi
        sleep 10
        waited=$((waited + 10))
    done
    if [ "$state" != "completed success" ]; then
        if [ -z "$run_id" ]; then
            echo "❌ CodeQL never started on $DEFAULT_BRANCH. Check that Actions are enabled for $FULL_REPO_NAME."
        else
            echo "❌ CodeQL was still running after $((CODEQL_WAIT_SECONDS / 60)) minutes."
            echo "   See https://github.com/$FULL_REPO_NAME/actions/runs/$run_id"
        fi
        exit 1
    fi
    echo "✅ CodeQL analysis finished"

    local attempt=1
    ALERT_COUNT=0
    while [ "$attempt" -le 12 ]; do
        ALERT_COUNT=$(gh api "repos/$FULL_REPO_NAME/code-scanning/alerts?state=open&ref=refs/heads/$DEFAULT_BRANCH&per_page=100" \
            --jq 'length' 2>/dev/null || true)
        [[ "$ALERT_COUNT" =~ ^[0-9]+$ ]] || ALERT_COUNT=0
        [ "$ALERT_COUNT" -gt 0 ] && break
        sleep 5
        attempt=$((attempt + 1))
    done
    if [ "$ALERT_COUNT" -eq 0 ]; then
        echo "❌ CodeQL finished but no open alerts appeared on $DEFAULT_BRANCH."
        exit 1
    fi
    echo "🚨 $ALERT_COUNT open code scanning alerts on $DEFAULT_BRANCH"
}

# Assign one default-branch alert to Copilot (agentic autofix) so a draft fix PR
# is ready by demo time. Prefers <rule_id>, else the first open alert. Only warns.
# Usage: assign_alert_to_copilot [rule_id]
assign_alert_to_copilot() {
    local rule="$1"
    local alerts number=""
    alerts=$(gh api "repos/$FULL_REPO_NAME/code-scanning/alerts?state=open&ref=refs/heads/$DEFAULT_BRANCH&per_page=100" 2>/dev/null || echo '[]')
    if [ -n "$rule" ]; then
        number=$(echo "$alerts" | jq -r --arg rule "$rule" '[.[] | select(.rule.id == $rule)][0].number // empty')
        [ -z "$number" ] && echo "ℹ️  No open '$rule' alert; assigning the first open alert instead."
    fi
    [ -z "$number" ] && number=$(echo "$alerts" | jq -r '.[0].number // empty')
    if [ -z "$number" ]; then
        echo "⚠️  No open alert to assign to Copilot."
        return 0
    fi
    echo "🤖 Assigning code scanning alert #$number to Copilot (agentic autofix)..."
    local assignee assignees=""
    for assignee in "${COPILOT_AUTOFIX_ASSIGNEES[@]}"; do
        assignees=$(gh api --method PATCH "repos/$FULL_REPO_NAME/code-scanning/alerts/$number" \
            -H "X-GitHub-Api-Version: $AI_SCAN_API_VERSION" -f "assignees[]=$assignee" \
            --jq '[.assignees[]?.login] | join(",")' 2>/dev/null || true)
        [[ ",$assignees," == *",$assignee,"* ]] && break
        assignees=""
    done
    if [ -n "$assignees" ]; then
        ASSIGNED_ALERT_URL="https://github.com/$FULL_REPO_NAME/security/code-scanning/$number"
        echo "✅ Alert #$number assigned to Copilot; a draft fix PR appears in about 10 minutes."
        return 0
    fi
    echo "⚠️  Could not assign alert #$number to Copilot. Agentic autofix must be on for the repo,"
    echo "   and the token needs a user (GitHub App tokens may not be able to assign Copilot)."
    echo "   Assign it from https://github.com/$FULL_REPO_NAME/security/code-scanning/$number (Assign to Copilot)."
}

# Write a key=value pair to $GITHUB_OUTPUT when running in GitHub Actions.
set_output() {
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "$1=$2" >> "$GITHUB_OUTPUT"
    fi
}

# Open a URL in the default browser (skipped in CI or when DEMO_NO_BROWSER is set).
open_url() {
    if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${DEMO_NO_BROWSER:-}" ]; then
        return 0
    fi
    if command -v open &> /dev/null; then
        open "$1" 2>/dev/null || true
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$1" > /dev/null 2>&1 || true
    fi
}

# Turn on GitHub Pages (built by the template's pages.yml workflow), run the first
# deploy of the default branch, and wait (bounded) for it. Sets PAGES_URL.
# Failures only warn: the repo and PRs are still usable without Pages.
setup_pages() {
    echo ""
    echo "🌐 Turning on GitHub Pages..."
    if ! gh api --method POST "repos/$FULL_REPO_NAME/pages" -f build_type=workflow --silent 2>/dev/null \
        && ! gh api "repos/$FULL_REPO_NAME/pages" --silent 2>/dev/null; then
        echo "⚠️  Could not turn on GitHub Pages for $FULL_REPO_NAME."
        echo "   Free accounts need a public repo; check Settings → Pages on GitHub."
        return 0
    fi
    PAGES_URL=$(gh api "repos/$FULL_REPO_NAME/pages" --jq '.html_url' 2>/dev/null || true)
    [ -z "$PAGES_URL" ] && PAGES_URL="https://$(echo "$OWNER" | tr '[:upper:]' '[:lower:]').github.io/$REPO_NAME/"
    set_output pages_url "$PAGES_URL"

    local attempt=1
    until gh workflow run "$PAGES_WORKFLOW" --repo "$FULL_REPO_NAME" --ref "$DEFAULT_BRANCH" > /dev/null 2>&1; do
        if [ "$attempt" -ge 5 ]; then
            echo "⚠️  Could not start the Pages deploy. Run it from the Actions tab: $PAGES_WORKFLOW"
            return 0
        fi
        sleep 3
        attempt=$((attempt + 1))
    done

    echo "🚀 Deploying $DEFAULT_BRANCH to $PAGES_URL (usually under a minute)..."
    local state=""
    attempt=1
    while [ "$attempt" -le 60 ]; do
        state=$(gh run list --repo "$FULL_REPO_NAME" --workflow "$PAGES_WORKFLOW" --event workflow_dispatch \
            --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || true)
        case "$state" in
            "completed success")
                echo "✅ Game is live: $PAGES_URL"
                return 0
                ;;
            completed\ *)
                echo "⚠️  The Pages deploy finished with '${state#completed }'. Check the Actions tab of $FULL_REPO_NAME."
                return 0
                ;;
        esac
        sleep 5
        attempt=$((attempt + 1))
    done
    echo "⚠️  The Pages deploy is still running; the site will appear at $PAGES_URL shortly."
}

# Validate required fields and referenced files for the selected workflow.
# Fails before any remote side effect so a config typo cannot strand a
# half-created repo on GitHub.
validate_selected_repo() {
    local missing=()

    [ -z "$TEMPLATE_REPO" ] && missing+=("template")
    [ -z "$REPO_BASE_NAME" ] && missing+=("repo_base_name")
    [ -z "$REPO_DESCRIPTION" ] && missing+=("repo_description")
    [ -z "$WORKFLOW" ] && missing+=("workflow")

    case "$VISIBILITY" in
        public|private|internal) ;;
        *)
            echo "❌ Invalid visibility '$VISIBILITY' (use public, private, or internal)"
            exit 1
            ;;
    esac

    case "$WORKFLOW" in
        repo_only)
            ;;
        branch_and_codespace)
            local branch
            branch=$(repo_cfg '.branch_name')
            [ -z "$branch" ] && missing+=("branch_name")
            if [ "$NO_CLONE" = true ]; then
                echo "❌ --no-clone is not supported for the branch_and_codespace workflow"
                exit 1
            fi
            ;;
        issue_and_codespace)
            local title body assignee
            title=$(repo_cfg '.issue.title')
            body=$(repo_cfg '.issue.body_file')
            assignee=$(repo_cfg '.issue.assignee')
            [ -z "$title" ] && missing+=("issue.title")
            [ -z "$body" ] && missing+=("issue.body_file")
            [ -z "$assignee" ] && missing+=("issue.assignee")
            if [ -n "$body" ] && [ ! -f "$SCRIPT_DIR/$body" ]; then
                echo "❌ issue.body_file not found: $SCRIPT_DIR/$body"
                exit 1
            fi
            ;;
        security_prs|code_review_prs)
            validate_pr_entries prs 1
            ;;
        ai_security)
            validate_pr_entries prs 1
            local seed_dir seed_msg
            seed_dir=$(repo_cfg '.seed.resource_dir')
            seed_msg=$(repo_cfg '.seed.commit_message')
            if [ -n "$seed_dir$seed_msg" ]; then
                [ -z "$seed_dir" ] && missing+=("seed.resource_dir")
                [ -z "$seed_msg" ] && missing+=("seed.commit_message")
                if [ -n "$seed_dir" ] && [ ! -d "$SCRIPT_DIR/$seed_dir" ]; then
                    echo "❌ seed.resource_dir not found: $SCRIPT_DIR/$seed_dir"
                    exit 1
                fi
            fi
            ;;
        stacked_prs)
            validate_pr_entries stack 2
            ;;
        *)
            echo "❌ Unknown workflow: $WORKFLOW"
            exit 1
            ;;
    esac

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "❌ Selected repo '$REPO_KEY' is missing required config field(s):"
        local field
        for field in "${missing[@]}"; do
            echo "   - $field"
        done
        exit 1
    fi
}

# Delete demo repos (demo-generated topic) owned by $OWNER that are older than
# $OLDER_THAN_HOURS. Never touches repos without the topic.
run_cleanup() {
    local endpoint="orgs/$OWNER/repos?per_page=100"
    [ "$OWNER" = "$CURRENT_USER" ] && endpoint="user/repos?affiliation=owner&per_page=100"

    if [ "$ALL" = true ]; then
        echo "⚠️  --all ignores the age cutoff: every '$DEMO_TOPIC' repo owned by $OWNER will be deleted, including demos still in use."
        echo "🧹 Looking for all '$DEMO_TOPIC' repos owned by $OWNER..."
    else
        echo "🧹 Looking for '$DEMO_TOPIC' repos owned by $OWNER older than ${OLDER_THAN_HOURS}h..."
    fi
    local candidates=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && candidates+=("$line")
    done < <(gh api --paginate "$endpoint" | jq -r \
        --arg owner "$OWNER" --arg topic "$DEMO_TOPIC" --argjson hours "$OLDER_THAN_HOURS" '
        .[]
        | select(.owner.login == $owner)
        | select((.topics // []) | index($topic))
        | select((.created_at | fromdateiso8601) < (now - $hours * 3600))
        | "\(.full_name)  (created \(.created_at))"')

    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "✅ Nothing to clean up."
        return
    fi
    printf '   %s\n' "${candidates[@]}"
    if [ "$DRY_RUN" = true ]; then
        echo "ℹ️  Dry run: would delete ${#candidates[@]} repo(s)."
        return
    fi
    if [ "$ASSUME_YES" != true ]; then
        local answer=""
        read -r -p "❓ Delete these ${#candidates[@]} repo(s)? [y/N] " answer || true
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            echo "Cancelled."
            return
        fi
    fi

    local failed=0 repo
    for line in "${candidates[@]}"; do
        repo="${line%% *}"
        if gh repo delete "$repo" --yes; then
            echo "🗑️  Deleted $repo"
        else
            failed=$((failed + 1))
        fi
    done
    if [ "$failed" -gt 0 ]; then
        echo "❌ $failed repo(s) could not be deleted. If this is a permissions error, run:"
        echo "   gh auth refresh -h github.com -s delete_repo"
        exit 1
    fi
}

# --- Preflight checks ---

echo "🚀 GitHub demo repository creation tool"
echo "======================================="

# `bash ./create-repo.sh` may not see PATH entries that only zsh startup files add
# (for example Homebrew's /opt/homebrew/bin), so add common install locations and
# the login shell's PATH before deciding a tool is missing.
for dir in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    if [ -d "$dir" ] && [[ ":$PATH:" != *":$dir:"* ]]; then
        PATH="$PATH:$dir"
    fi
done
if ! command -v gh &> /dev/null || ! command -v jq &> /dev/null; then
    if [ -n "${SHELL:-}" ] && [ -x "$SHELL" ]; then
        LOGIN_PATH=$("$SHELL" -lic 'printf "\n__DEMO_PATH__%s\n" "$PATH"' 2>/dev/null </dev/null | sed -n 's/^__DEMO_PATH__//p' | tail -1 || true)
        [ -n "$LOGIN_PATH" ] && PATH="$PATH:$LOGIN_PATH"
    fi
fi
export PATH

if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI (gh) was not found on PATH."
    echo "   If 'gh --version' works in your terminal, run 'command -v gh' there and"
    echo "   make sure that folder is on PATH for bash. Otherwise install it: brew install gh"
    echo "   PATH seen by this script: $PATH"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "❌ jq is not installed. Please install it first:"
    echo "   brew install jq"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    exit 1
fi

if [ "$SERVE" = true ] && ! command -v npm &> /dev/null; then
    echo "❌ --serve needs Node.js (npm). Install it from https://nodejs.org/"
    exit 1
fi

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "❌ Config file is not valid JSON: $CONFIG_FILE"
    exit 1
fi

echo "🔐 Checking GitHub authentication..."
if ! gh auth status &> /dev/null; then
    if [ "$NON_INTERACTIVE" = true ]; then
        echo "❌ Not authenticated with GitHub. In non-interactive mode, log in first"
        echo "   (gh auth login) or set GH_TOKEN."
        exit 1
    fi
    echo "📝 Not logged in to GitHub. Starting login process..."
    # delete_repo lets --cleanup remove this account's old demo repos.
    gh auth login -s delete_repo
else
    echo "✅ Already authenticated with GitHub"
fi

echo "👤 Getting current GitHub username..."
# On failure gh prints the error JSON to stdout, so discard output unless the call succeeds.
CURRENT_USER=$(gh api user --jq '.login' 2>/dev/null) || CURRENT_USER=""
USER_TOKEN=true
if [ -z "$CURRENT_USER" ] && [ "$NON_INTERACTIVE" = true ]; then
    # GitHub App installation tokens cannot read /user.
    CURRENT_USER="${GITHUB_ACTOR:-github-app}"
    USER_TOKEN=false
fi
if [ -z "$CURRENT_USER" ]; then
    echo "❌ Failed to get current GitHub username"
    exit 1
fi
echo "✅ Current user: $CURRENT_USER"

# --- Load config ---

ORG_NAME=$(cfg '.org')
if [ -z "$ORG_NAME" ]; then
    echo "❌ Config is missing top-level 'org'"
    exit 1
fi

if [ "$CLEANUP" = true ]; then
    OWNER="${OWNER_OVERRIDE:-$CURRENT_USER}"
    run_cleanup
    exit 0
fi

CODESPACE_MACHINE=$(cfg '.codespace_machine')

REPO_COUNT=$(jq '.repos | length' "$CONFIG_FILE")
if [ "$REPO_COUNT" -eq 0 ]; then
    echo "❌ Config has no repos defined"
    exit 1
fi

# --- Template selection ---

if [ "$NON_INTERACTIVE" = true ]; then
    SELECTED_INDEX=$(jq --arg key "$TEMPLATE_KEY" \
        '[.repos[].key] | index($key) // empty' "$CONFIG_FILE")
    if [ -z "$SELECTED_INDEX" ]; then
        echo "❌ Unknown template key: $TEMPLATE_KEY"
        echo "   Valid keys: $(jq -r '[.repos[].key] | join(", ")' "$CONFIG_FILE")"
        exit 1
    fi
    echo "🎯 Selected template: $TEMPLATE_KEY"
else
    echo ""
    echo "📋 Available templates:"
    i=0
    while [ "$i" -lt "$REPO_COUNT" ]; do
        display=$(jq -r ".repos[$i].display_name // .repos[$i].key" "$CONFIG_FILE")
        template=$(jq -r ".repos[$i].template" "$CONFIG_FILE")
        template_org=$(jq -r ".repos[$i].template_org // \"$ORG_NAME\"" "$CONFIG_FILE")
        description_short=$(jq -r ".repos[$i].description_short // empty" "$CONFIG_FILE")
        workflow_hint=$(jq -r ".repos[$i].workflow_hint // empty" "$CONFIG_FILE")

        echo "$((i + 1)). $display ($template_org/$template)"
        [ -n "$description_short" ] && echo "   $description_short"
        [ -n "$workflow_hint" ] && echo "   → $workflow_hint"
        echo ""
        i=$((i + 1))
    done

    while true; do
        read -r -p "🎯 Select template (1-$REPO_COUNT): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$REPO_COUNT" ]; then
            SELECTED_INDEX=$((choice - 1))
            break
        fi
        echo "❌ Invalid choice. Please enter a number between 1 and $REPO_COUNT."
    done
fi

# --- Resolve selected repo fields ---

REPO_KEY=$(repo_cfg '.key')
TEMPLATE_NAME=$(repo_cfg '.template')
TEMPLATE_ORG=$(repo_cfg '.template_org')
[ -z "$TEMPLATE_ORG" ] && TEMPLATE_ORG="$ORG_NAME"
TEMPLATE_REPO="$TEMPLATE_ORG/$TEMPLATE_NAME"
REPO_BASE_NAME=$(repo_cfg '.repo_base_name')
REPO_DESCRIPTION=$(repo_cfg '.repo_description')
WORKFLOW=$(repo_cfg '.workflow')
VISIBILITY=$(repo_cfg '.visibility')
[ -z "$VISIBILITY" ] && VISIBILITY="private"
PAGES=$(repo_cfg '.pages')

# Owner precedence: --owner, then the entry's "owner" ("org" = top-level org),
# then the logged-in account. App tokens have no account, so they use the org.
CONFIG_OWNER=$(repo_cfg '.owner')
[ "$CONFIG_OWNER" = "org" ] && CONFIG_OWNER="$ORG_NAME"
if [ -n "$OWNER_OVERRIDE" ]; then
    OWNER="$OWNER_OVERRIDE"
elif [ -n "$CONFIG_OWNER" ]; then
    OWNER="$CONFIG_OWNER"
elif [ "$USER_TOKEN" = true ]; then
    OWNER="$CURRENT_USER"
else
    OWNER="$ORG_NAME"
fi
echo "🏢 Target owner: $OWNER"

# Entries with "serve": true start the local preview whenever there is a local clone.
if [ "$(repo_cfg '.serve')" = "true" ] && [ "$NO_CLONE" = false ] && [ "$SERVE" = false ]; then
    if command -v npm &> /dev/null; then
        SERVE=true
    else
        echo "⚠️  Skipping the local preview: Node.js (npm) is not installed."
    fi
fi

# Read summary lines into a Bash array (Bash 3.2 compatible — no mapfile).
SUMMARY_LINES=()
while IFS= read -r line; do
    [ -n "$line" ] && SUMMARY_LINES+=("$line")
done < <(jq -r ".repos[$SELECTED_INDEX].summary_lines[]? // empty" "$CONFIG_FILE")

# --- Validate before any remote side effects ---

validate_selected_repo

# --- Repository creation ---

RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
REPO_NAME="${REPO_BASE_NAME}-${RANDOM_SUFFIX}"
FULL_REPO_NAME="${OWNER}/${REPO_NAME}"

echo ""
echo "📦 Creating repository: $FULL_REPO_NAME"
echo "🏗️  Using template: $TEMPLATE_REPO"

gh repo create "$FULL_REPO_NAME" \
    --template="$TEMPLATE_REPO" \
    "--$VISIBILITY" \
    --description="$REPO_DESCRIPTION"

echo "✅ Repository created successfully: $FULL_REPO_NAME"
set_output repo_name "$FULL_REPO_NAME"
set_output repo_url "https://github.com/$FULL_REPO_NAME"

tag_demo_repo

wait_for_repo_ready
echo "📍 Default branch: $DEFAULT_BRANCH"

# --- Clone repository locally ---

REPOS_DIR="$HOME/repos"
CLONE_PATH="$REPOS_DIR/$REPO_NAME"
if [ "$NO_CLONE" = true ]; then
    CLONE_PATH="(skipped: --no-clone)"
    echo "⏭️  Skipping local clone (--no-clone)"
else
    if [ ! -d "$REPOS_DIR" ]; then
        echo "📁 Creating $REPOS_DIR directory..."
        mkdir -p "$REPOS_DIR"
    fi

    echo "📥 Cloning repository to $CLONE_PATH..."
    gh repo clone "$FULL_REPO_NAME" "$CLONE_PATH" -- --quiet
    echo "✅ Repository cloned to $CLONE_PATH"
fi

# --- Post-creation workflow ---

case $WORKFLOW in
    "branch_and_codespace")
        echo ""
        echo "🌿 Creating new branch and codespace..."

        cd "$CLONE_PATH"

        BRANCH_NAME=$(repo_cfg '.branch_name')
        echo "🌿 Creating branch: $BRANCH_NAME from $DEFAULT_BRANCH"
        git checkout "$DEFAULT_BRANCH"
        git checkout -b "$BRANCH_NAME"
        git push -u origin "$BRANCH_NAME"
        echo "✅ Branch created and pushed: $BRANCH_NAME"

        start_codespace "$BRANCH_NAME"
        ;;

    "issue_and_codespace")
        echo ""
        echo "📝 Creating issue and codespace..."

        ISSUE_TITLE=$(repo_cfg '.issue.title')
        ISSUE_BODY_FILE="$SCRIPT_DIR/$(repo_cfg '.issue.body_file')"
        ISSUE_ASSIGNEE=$(repo_cfg '.issue.assignee')

        gh issue create \
            --repo "$FULL_REPO_NAME" \
            --title "$ISSUE_TITLE" \
            --body-file "$ISSUE_BODY_FILE" \
            --assignee "$ISSUE_ASSIGNEE"
        echo "✅ Issue created and assigned to $ISSUE_ASSIGNEE"

        start_codespace
        ;;

    "repo_only")
        echo ""
        echo "✅ Repository creation complete (no additional actions needed)"
        ;;

    "security_prs")
        echo ""
        echo "🔒 Setting up security demo with PRs..."

        ENABLE_SECURITY=$(repo_cfg '.enable_security_features')
        if [ "$ENABLE_SECURITY" = "true" ]; then
            echo "🛡️  Enabling security features..."
            gh api "repos/$FULL_REPO_NAME/vulnerability-alerts" -X PUT --silent 2>/dev/null
            gh api "repos/$FULL_REPO_NAME/automated-security-fixes" -X PUT --silent 2>/dev/null
            # Private repos need Advanced Security before Code Scanning default setup.
            gh api "repos/$FULL_REPO_NAME" -X PATCH \
                -f 'security_and_analysis[advanced_security][status]=enabled' --silent
            # "codeql": "advanced" means the template ships its own CodeQL workflow;
            # default setup would make GitHub reject that workflow's uploads.
            if [ "$(repo_cfg '.codeql')" = "advanced" ]; then
                echo "ℹ️  Using the template's CodeQL workflow (advanced setup)"
            else
                gh api "repos/$FULL_REPO_NAME/code-scanning/default-setup" -X PATCH \
                    -f state=configured -f query_suite=default --silent
            fi
            echo "✅ Dependabot alerts, security updates, and Code Scanning enabled"
        fi

        clone_to_temp

        PR_COUNT=$(jq ".repos[$SELECTED_INDEX].prs | length" "$CONFIG_FILE")
        i=0
        while [ "$i" -lt "$PR_COUNT" ]; do
            pr_branch=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].branch" "$CONFIG_FILE")
            pr_resource_dir=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].resource_dir" "$CONFIG_FILE")
            pr_body_file=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].body_file" "$CONFIG_FILE")
            pr_commit_msg=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].commit_message" "$CONFIG_FILE")
            pr_title=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].title" "$CONFIG_FILE")

            create_pr_from_resources \
                "$pr_branch" \
                "$pr_resource_dir" \
                "$pr_body_file" \
                "$pr_commit_msg" \
                "$pr_title"
            i=$((i + 1))
        done
        ;;

    "ai_security")
        echo ""
        echo "🤖 Setting up AI Scan + agentic autofix demo..."

        # The template runs CodeQL through its own advanced workflow. Default setup
        # is deliberately not enabled: it would reject that workflow's uploads.
        CODEQL_WORKFLOW=$(repo_cfg '.codeql_workflow')
        [ -z "$CODEQL_WORKFLOW" ] && CODEQL_WORKFLOW="codeql-advanced.yml"
        # Private repos need Advanced Security before code scanning results are accepted.
        gh api "repos/$FULL_REPO_NAME" -X PATCH \
            -f 'security_and_analysis[advanced_security][status]=enabled' --silent
        echo "✅ Advanced Security enabled"
        enable_ai_scan

        clone_to_temp

        SEED_DIR=$(repo_cfg '.seed.resource_dir')
        if [ -n "$SEED_DIR" ]; then
            echo "🌱 Adding extra default-branch code for CodeQL to flag..."
            cp -R "$SCRIPT_DIR/$SEED_DIR"/. .
            git add -A
            git commit -m "$(repo_cfg '.seed.commit_message')" --quiet
            git push origin "$DEFAULT_BRANCH" --quiet 2>/dev/null
        else
            gh workflow run "$CODEQL_WORKFLOW" --repo "$FULL_REPO_NAME" --ref "$DEFAULT_BRANCH" > /dev/null
        fi
        wait_for_codeql "$(git rev-parse HEAD)"

        assign_alert_to_copilot "$(repo_cfg '.autofix.preassign_rule')"

        PR_COUNT=$(jq ".repos[$SELECTED_INDEX].prs | length" "$CONFIG_FILE")
        i=0
        while [ "$i" -lt "$PR_COUNT" ]; do
            create_pr_from_resources \
                "$(jq -r ".repos[$SELECTED_INDEX].prs[$i].branch" "$CONFIG_FILE")" \
                "$(jq -r ".repos[$SELECTED_INDEX].prs[$i].resource_dir" "$CONFIG_FILE")" \
                "$(jq -r ".repos[$SELECTED_INDEX].prs[$i].body_file" "$CONFIG_FILE")" \
                "$(jq -r ".repos[$SELECTED_INDEX].prs[$i].commit_message" "$CONFIG_FILE")" \
                "$(jq -r ".repos[$SELECTED_INDEX].prs[$i].title" "$CONFIG_FILE")"
            i=$((i + 1))
        done

        if [ "$NO_CLONE" = false ]; then
            git -C "$CLONE_PATH" pull --quiet origin "$DEFAULT_BRANCH"
            git -C "$CLONE_PATH" fetch --quiet origin
        fi
        PULLS_URL="https://github.com/$FULL_REPO_NAME/pulls"
        ALERTS_URL="https://github.com/$FULL_REPO_NAME/security/code-scanning"
        set_output pulls_url "$PULLS_URL"
        set_output alerts_url "$ALERTS_URL"
        ;;

    "code_review_prs")
        echo ""
        echo "🔍 Setting up Copilot Code Review demo with PRs..."

        clone_to_temp

        PR_COUNT=$(jq ".repos[$SELECTED_INDEX].prs | length" "$CONFIG_FILE")
        i=0
        while [ "$i" -lt "$PR_COUNT" ]; do
            pr_branch=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].branch" "$CONFIG_FILE")
            pr_resource_dir=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].resource_dir" "$CONFIG_FILE")
            pr_body_file=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].body_file" "$CONFIG_FILE")
            pr_commit_msg=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].commit_message" "$CONFIG_FILE")
            pr_title=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].title" "$CONFIG_FILE")
            # "request_review": false leaves the PR for the presenter to request live.
            pr_request_review=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].request_review != false" "$CONFIG_FILE")

            create_pr_from_resources \
                "$pr_branch" \
                "$pr_resource_dir" \
                "$pr_body_file" \
                "$pr_commit_msg" \
                "$pr_title"
            if [ "$pr_request_review" = true ]; then
                request_copilot_review "$CREATED_PR_NUMBER"
            else
                echo "👋 Copilot Code Review not requested on PR #$CREATED_PR_NUMBER: request it live from the PR (Reviewers -> Copilot)."
            fi
            i=$((i + 1))
        done

        # Make the PR branches visible in the local clone (Copilot app, editor).
        if [ "$NO_CLONE" = false ]; then
            git -C "$CLONE_PATH" fetch --quiet origin
            echo "✅ PR branches fetched into $CLONE_PATH"
        fi
        PULLS_URL="https://github.com/$FULL_REPO_NAME/pulls"
        set_output pulls_url "$PULLS_URL"
        ;;

    "stacked_prs")
        echo ""
        echo "🥞 Setting up stacked PRs demo..."

        clone_to_temp

        STACK_COUNT=$(jq ".repos[$SELECTED_INDEX].stack | length" "$CONFIG_FILE")
        STACK_PR_NUMBERS=()
        prev_branch="$DEFAULT_BRANCH"
        i=0
        while [ "$i" -lt "$STACK_COUNT" ]; do
            layer_branch=$(jq -r ".repos[$SELECTED_INDEX].stack[$i].branch" "$CONFIG_FILE")
            layer_resource_dir=$(jq -r ".repos[$SELECTED_INDEX].stack[$i].resource_dir" "$CONFIG_FILE")
            layer_body_file=$(jq -r ".repos[$SELECTED_INDEX].stack[$i].body_file" "$CONFIG_FILE")
            layer_commit_msg=$(jq -r ".repos[$SELECTED_INDEX].stack[$i].commit_message" "$CONFIG_FILE")
            layer_title=$(jq -r ".repos[$SELECTED_INDEX].stack[$i].title" "$CONFIG_FILE")

            create_pr_from_resources \
                "$layer_branch" \
                "$layer_resource_dir" \
                "$layer_body_file" \
                "$layer_commit_msg" \
                "$layer_title" \
                "$prev_branch"
            STACK_PR_NUMBERS+=("$CREATED_PR_NUMBER")
            TOP_PR_URL="$CREATED_PR_URL"
            prev_branch="$layer_branch"
            i=$((i + 1))
        done
        set_output top_pr_url "$TOP_PR_URL"

        register_stack
        ;;
esac

if [ "$PAGES" = "true" ]; then
    setup_pages
fi

# --- Summary ---

echo ""
echo "🎉 Setup complete!"
echo ""
echo "📋 Summary:"
echo "   Repository: https://github.com/$FULL_REPO_NAME"
echo "   Cloned to: $CLONE_PATH"
echo "   Template: $TEMPLATE_REPO"
echo "   User: $CURRENT_USER"
if [ -n "${TOP_PR_URL:-}" ]; then
    echo "   Top of stack: $TOP_PR_URL"
fi
if [ -n "${PULLS_URL:-}" ]; then
    echo "   Pull requests: $PULLS_URL"
fi
if [ -n "${ALERTS_URL:-}" ]; then
    echo "   Code scanning alerts: $ALERTS_URL"
fi
if [ -n "${ASSIGNED_ALERT_URL:-}" ]; then
    echo "   Assigned to Copilot: $ASSIGNED_ALERT_URL"
fi
if [ -n "${PAGES_URL:-}" ]; then
    echo "   Game (GitHub Pages): $PAGES_URL"
fi
for line in "${SUMMARY_LINES[@]}"; do
    echo "   $line"
done

if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "issue_and_codespace" ]]; then
    echo ""
    echo "💡 You can access your codespace at: https://github.com/codespaces"
fi

echo ""
echo "✨ All done!"

# Open the PR first and the game last so the game is the tab in front.
if [ -n "${PAGES_URL:-}" ]; then
    [ -n "${TOP_PR_URL:-}" ] && open_url "$TOP_PR_URL"
    open_url "$PAGES_URL"
fi
if [ -n "${ALERTS_URL:-}" ]; then
    open_url "$ALERTS_URL"
fi
if [ -n "${PULLS_URL:-}" ]; then
    open_url "$PULLS_URL"
fi

# --- Optional local preview ---

if [ "$SERVE" = true ]; then
    cleanup_temp
    cd "$CLONE_PATH"
    if [ ! -f package.json ]; then
        echo "⚠️  --serve: this template has no package.json, so there is nothing to serve."
        exit 0
    fi
    git fetch --quiet origin
    # Start on the default branch so the audience sees the app before the PRs land.
    git checkout --quiet "$DEFAULT_BRANCH"
    echo ""
    echo "🌐 Serving $DEFAULT_BRANCH (before any PRs are merged). Ctrl+C to stop."
    if jq -e '.scripts.layer' package.json > /dev/null; then
        echo "   From another terminal: cd \"$CLONE_PATH\""
        echo "     npm run layer -- 1..3   preview a layer of the stack"
        echo "     npm run layer -- 0      back to $DEFAULT_BRANCH; after merging the stack, this pulls the merged code"
        echo "   Then reload the browser."
    fi
    npm start -- --open
fi
