#!/bin/bash

# Consolidated script to create GitHub repos from various templates
# with different workflows based on the selected template.
#
# All repo/org metadata lives in config.json next to this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

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
    gh repo clone "$FULL_REPO_NAME" --quiet
    cd "$REPO_NAME"
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
# Usage: create_pr_from_resources <branch> <resource_dir> <body_file> <commit_msg> <pr_title>
#   resource_dir and body_file are paths relative to SCRIPT_DIR.
#   body_file must live inside resource_dir; it is removed from the working
#   tree after copy so it isn't committed into the demo branch.
create_pr_from_resources() {
    local branch_name="$1"
    local resource_dir="$2"
    local body_file="$3"
    local commit_msg="$4"
    local pr_title="$5"

    local abs_resource_dir="$SCRIPT_DIR/$resource_dir"
    local abs_body_file="$SCRIPT_DIR/$body_file"
    local body_basename
    body_basename=$(basename "$body_file")

    echo "📝 Creating PR: $pr_title..."
    git checkout -b "$branch_name" "$DEFAULT_BRANCH"
    cp -R "$abs_resource_dir"/ .
    # Preserve previous behavior: don't commit the PR body file.
    rm -f "$body_basename"
    git add -A
    git commit -m "$commit_msg" --quiet
    git push -u origin "$branch_name" --quiet 2>/dev/null

    gh pr create \
        --repo "$FULL_REPO_NAME" \
        --head "$branch_name" \
        --base "$DEFAULT_BRANCH" \
        --title "$pr_title" \
        --body-file "$abs_body_file"

    echo "✅ PR created: $pr_title"
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

    case "$WORKFLOW" in
        repo_only)
            ;;
        branch_and_codespace)
            local branch
            branch=$(repo_cfg '.branch_name')
            [ -z "$branch" ] && missing+=("branch_name")
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
        security_prs)
            local pr_count
            pr_count=$(jq ".repos[$SELECTED_INDEX].prs | length // 0" "$CONFIG_FILE")
            if [ "$pr_count" -eq 0 ]; then
                missing+=("prs[]")
            else
                local i=0
                while [ "$i" -lt "$pr_count" ]; do
                    local branch resource_dir body commit title
                    branch=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].branch // empty" "$CONFIG_FILE")
                    resource_dir=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].resource_dir // empty" "$CONFIG_FILE")
                    body=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].body_file // empty" "$CONFIG_FILE")
                    commit=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].commit_message // empty" "$CONFIG_FILE")
                    title=$(jq -r ".repos[$SELECTED_INDEX].prs[$i].title // empty" "$CONFIG_FILE")
                    [ -z "$branch" ] && missing+=("prs[$i].branch")
                    [ -z "$resource_dir" ] && missing+=("prs[$i].resource_dir")
                    [ -z "$body" ] && missing+=("prs[$i].body_file")
                    [ -z "$commit" ] && missing+=("prs[$i].commit_message")
                    [ -z "$title" ] && missing+=("prs[$i].title")
                    if [ -n "$resource_dir" ] && [ ! -d "$SCRIPT_DIR/$resource_dir" ]; then
                        echo "❌ prs[$i].resource_dir not found: $SCRIPT_DIR/$resource_dir"
                        exit 1
                    fi
                    if [ -n "$body" ] && [ ! -f "$SCRIPT_DIR/$body" ]; then
                        echo "❌ prs[$i].body_file not found: $SCRIPT_DIR/$body"
                        exit 1
                    fi
                    i=$((i + 1))
                done
            fi
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

# --- Preflight checks ---

echo "🚀 GitHub demo repository creation tool"
echo "======================================="

if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI is not installed. Please install it first:"
    echo "   brew install gh"
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

if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "❌ Config file is not valid JSON: $CONFIG_FILE"
    exit 1
fi

echo "🔐 Checking GitHub authentication..."
if ! gh auth status &> /dev/null; then
    echo "📝 Not logged in to GitHub. Starting login process..."
    gh auth login
else
    echo "✅ Already authenticated with GitHub"
fi

echo "👤 Getting current GitHub username..."
CURRENT_USER=$(gh api user --jq '.login')
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
echo "🏢 Target org: $ORG_NAME"

CODESPACE_MACHINE=$(cfg '.codespace_machine')

REPO_COUNT=$(jq '.repos | length' "$CONFIG_FILE")
if [ "$REPO_COUNT" -eq 0 ]; then
    echo "❌ Config has no repos defined"
    exit 1
fi

# --- Template selection ---

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
    read -p "🎯 Select template (1-$REPO_COUNT): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$REPO_COUNT" ]; then
        SELECTED_INDEX=$((choice - 1))
        break
    fi
    echo "❌ Invalid choice. Please enter a number between 1 and $REPO_COUNT."
done

# --- Resolve selected repo fields ---

REPO_KEY=$(repo_cfg '.key')
TEMPLATE_NAME=$(repo_cfg '.template')
TEMPLATE_ORG=$(repo_cfg '.template_org')
[ -z "$TEMPLATE_ORG" ] && TEMPLATE_ORG="$ORG_NAME"
TEMPLATE_REPO="$TEMPLATE_ORG/$TEMPLATE_NAME"
REPO_BASE_NAME=$(repo_cfg '.repo_base_name')
REPO_DESCRIPTION=$(repo_cfg '.repo_description')
WORKFLOW=$(repo_cfg '.workflow')

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
FULL_REPO_NAME="${ORG_NAME}/${REPO_NAME}"

echo ""
echo "📦 Creating repository: $FULL_REPO_NAME"
echo "🏗️  Using template: $TEMPLATE_REPO"

gh repo create "$FULL_REPO_NAME" \
    --template="$TEMPLATE_REPO" \
    --private \
    --description="$REPO_DESCRIPTION"

echo "✅ Repository created successfully: $FULL_REPO_NAME"

echo "⏳ Waiting for template to be fully processed..."
sleep 3

# --- Clone repository locally ---

REPOS_DIR="$HOME/repos"
if [ ! -d "$REPOS_DIR" ]; then
    echo "📁 Creating $REPOS_DIR directory..."
    mkdir -p "$REPOS_DIR"
fi

echo "📥 Cloning repository to $REPOS_DIR/$REPO_NAME..."
gh repo clone "$FULL_REPO_NAME" "$REPOS_DIR/$REPO_NAME" -- --quiet
echo "✅ Repository cloned to $REPOS_DIR/$REPO_NAME"

DEFAULT_BRANCH=$(gh api "repos/$FULL_REPO_NAME" --jq '.default_branch')
echo "📍 Default branch: $DEFAULT_BRANCH"

# --- Post-creation workflow ---

case $WORKFLOW in
    "branch_and_codespace")
        echo ""
        echo "🌿 Creating new branch and codespace..."

        cd "$REPOS_DIR/$REPO_NAME"

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
            gh api "repos/$FULL_REPO_NAME/code-scanning/default-setup" -X PATCH \
                -f state=configured -f query_suite=default --silent 2>/dev/null
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
esac

# --- Summary ---

echo ""
echo "🎉 Setup complete!"
echo ""
echo "📋 Summary:"
echo "   Repository: https://github.com/$FULL_REPO_NAME"
echo "   Cloned to: $REPOS_DIR/$REPO_NAME"
echo "   Template: $TEMPLATE_REPO"
echo "   User: $CURRENT_USER"
for line in "${SUMMARY_LINES[@]}"; do
    echo "   $line"
done

if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "issue_and_codespace" ]]; then
    echo ""
    echo "💡 You can access your codespace at: https://github.com/codespaces"
fi

echo ""
echo "✨ All done!"
