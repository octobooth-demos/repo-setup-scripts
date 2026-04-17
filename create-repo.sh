#!/bin/bash

# Consolidated script to create GitHub repos from various templates
# with different workflows based on the selected template

set -e  # Exit on any error

# Resolve path to resource files (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default codespace machine type (omit --machine flag to use the smallest available)
CODESPACE_MACHINE="standardLinux32gb"

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

clone_to_temp() {
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    gh repo clone "$FULL_REPO_NAME" --quiet
    cd "$REPO_NAME"
}

# Start a codespace for the current repo
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

# Create a PR branch from local resource files
# Usage: create_pr_from_resources <branch_name> <resource_subdir> <commit_msg> <pr_title>
create_pr_from_resources() {
    local branch_name="$1"
    local resource_subdir="$2"
    local commit_msg="$3"
    local pr_title="$4"
    local body_file="$SCRIPT_DIR/resources/security-octo-supply/$resource_subdir/pr-body.md"

    echo "📝 Creating PR: $pr_title..."
    git checkout -b "$branch_name" "$DEFAULT_BRANCH"
    cp -R "$SCRIPT_DIR/resources/security-octo-supply/$resource_subdir/" .
    rm -f pr-body.md  # Don't include the PR body file in the commit
    git add -A
    git commit -m "$commit_msg" --quiet
    git push -u origin "$branch_name" --quiet 2>/dev/null

    gh pr create \
        --repo "$FULL_REPO_NAME" \
        --head "$branch_name" \
        --base "$DEFAULT_BRANCH" \
        --title "$pr_title" \
        --body-file "$body_file"

    echo "✅ PR created: $pr_title"
}

# --- Preflight checks ---

echo "🚀 GitHub demo repository creation tool"
echo "======================================="

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI is not installed. Please install it first:"
    echo "   brew install gh"
    exit 1
fi

# Ensure we're logged in to GitHub
echo "🔐 Checking GitHub authentication..."
if ! gh auth status &> /dev/null; then
    echo "📝 Not logged in to GitHub. Starting login process..."
    gh auth login
else
    echo "✅ Already authenticated with GitHub"
fi

# Get current GitHub username
echo "👤 Getting current GitHub username..."
CURRENT_USER=$(gh api user --jq '.login')
if [ -z "$CURRENT_USER" ]; then
    echo "❌ Failed to get current GitHub username"
    exit 1
fi
echo "✅ Current user: $CURRENT_USER"

# Prompt for target organization
echo ""
read -p "🏢 Enter target organization (default: octobooth): " ORG_NAME
ORG_NAME="${ORG_NAME:-octobooth}"
echo "✅ Target org: $ORG_NAME"

# --- Template selection ---

echo ""
echo "📋 Available templates:"
echo "1. Game Repository ($ORG_NAME/gh-game)"
echo "   CLI games written in Go"
echo "   → Creates repo + new branch + codespace"
echo ""
echo "2. React Dashboard ($ORG_NAME/task-dashboard)"
echo "   Core React app for demoing code"
echo "   → Creates repo + codespace + issue assigned to Copilot"
echo ""
echo "3. Mona Gallery ($ORG_NAME/mona-gallery)"
echo "   Insecure version of Mona Gallery for security demos"
echo "   → Creates repo only"
echo ""
echo "4. Secure Code (github-samples/securing-your-code)"
echo "   Repo with a full set of labs and exercises about security"
echo "   → Creates repo only"
echo ""
echo "5. Security Supply Chain ($ORG_NAME/security-octo-supply)"
echo "   Security demo with TypeScript and PHP vulnerabilities"
echo "   → Creates repo + two demo PRs"
echo ""
echo "6. Tailspin Toys ($ORG_NAME/tailspin-toys)"
echo "   Game crowdfunding platform (Flask + Astro/Svelte)"
echo "   → Creates repo + issue assigned to Copilot + codespace"
echo ""

while true; do
    read -p "🎯 Select template (1-6): " choice
    case $choice in
        1)
            TEMPLATE_REPO="$ORG_NAME/gh-game"
            REPO_BASE_NAME="gh-game"
            REPO_DESCRIPTION="CLI games written in Go"
            WORKFLOW="branch_and_codespace"
            SUMMARY_LINES=("Branch: new-game" "Codespace: Created")
            break
            ;;
        2)
            TEMPLATE_REPO="$ORG_NAME/task-dashboard"
            REPO_BASE_NAME="task-dashboard"
            REPO_DESCRIPTION="Core React app for demoing code"
            WORKFLOW="codespace_and_issue"
            SUMMARY_LINES=("Issue: Created and assigned to Copilot" "Codespace: Created")
            break
            ;;
        3)
            TEMPLATE_REPO="$ORG_NAME/mona-gallery"
            REPO_BASE_NAME="mona-gallery"
            REPO_DESCRIPTION="Mona Gallery for security demos"
            WORKFLOW="repo_only"
            SUMMARY_LINES=("Status: Repository ready for use")
            break
            ;;
        4)
            TEMPLATE_REPO="github-samples/securing-your-code"
            REPO_BASE_NAME="securing-your-code"
            REPO_DESCRIPTION="Security labs and exercises"
            WORKFLOW="repo_only"
            SUMMARY_LINES=("Status: Repository ready for use")
            break
            ;;
        5)
            TEMPLATE_REPO="$ORG_NAME/template-security-octo-supply"
            REPO_BASE_NAME="security-octo-supply"
            REPO_DESCRIPTION="Security supply chain demo"
            WORKFLOW="security_prs"
            SUMMARY_LINES=("Security features: Enabled" "PRs: TypeScript + PHP demo PRs created")
            break
            ;;
        6)
            TEMPLATE_REPO="$ORG_NAME/template-tailspin-toys"
            REPO_BASE_NAME="tailspin-toys"
            REPO_DESCRIPTION="Game crowdfunding platform"
            WORKFLOW="issue_and_codespace"
            SUMMARY_LINES=("Issue: Created and assigned to Copilot" "Codespace: Created")
            break
            ;;
        *)
            echo "❌ Invalid choice. Please select 1, 2, 3, 4, 5, or 6."
            ;;
    esac
done

# --- Repository creation ---

# Create repository name
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

# Wait a moment for template to be fully processed
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

# Resolve the default branch for workflows that need it
DEFAULT_BRANCH=$(gh api "repos/$FULL_REPO_NAME" --jq '.default_branch')
echo "📍 Default branch: $DEFAULT_BRANCH"

# --- Post-creation workflow ---

case $WORKFLOW in
    "branch_and_codespace")
        echo ""
        echo "🌿 Creating new branch and codespace..."
        
        cd "$REPOS_DIR/$REPO_NAME"
        
        BRANCH_NAME="new-game"
        echo "🌿 Creating branch: $BRANCH_NAME from $DEFAULT_BRANCH"
        git checkout "$DEFAULT_BRANCH"
        git checkout -b "$BRANCH_NAME"
        git push -u origin "$BRANCH_NAME"
        echo "✅ Branch created and pushed: $BRANCH_NAME"
        
        start_codespace "$BRANCH_NAME"
        ;;
        
    "codespace_and_issue")
        echo ""
        echo "📝 Creating issue and codespace..."
        
        ISSUE_BODY_FILE="$SCRIPT_DIR/resources/task-dashboard/issue-body.md"
        if [ ! -f "$ISSUE_BODY_FILE" ]; then
            echo "❌ Issue body file not found: $ISSUE_BODY_FILE"
            exit 1
        fi
        
        gh issue create \
            --repo "$FULL_REPO_NAME" \
            --title "Create Playwright tests to ensure functionality" \
            --body-file "$ISSUE_BODY_FILE" \
            --assignee "@copilot"
        echo "✅ Issue created and assigned to Copilot"
        
        start_codespace
        ;;
        
    "repo_only")
        echo ""
        echo "✅ Repository creation complete (no additional actions needed)"
        ;;
        
    "issue_and_codespace")
        echo ""
        echo "📝 Creating issue and codespace..."
        
        ISSUE_BODY_FILE="$SCRIPT_DIR/resources/$REPO_BASE_NAME/issue-body.md"
        if [ ! -f "$ISSUE_BODY_FILE" ]; then
            echo "❌ Issue body file not found: $ISSUE_BODY_FILE"
            exit 1
        fi
        
        gh issue create \
            --repo "$FULL_REPO_NAME" \
            --title "Add filtering by publisher and category" \
            --body-file "$ISSUE_BODY_FILE" \
            --assignee "@copilot"
        echo "✅ Issue created and assigned to Copilot"
        
        start_codespace
        ;;
        
    "security_prs")
        echo ""
        echo "🔒 Setting up security demo with PRs..."
        
        if [ ! -d "$SCRIPT_DIR/resources/security-octo-supply" ]; then
            echo "❌ Resource directory not found: $SCRIPT_DIR/resources/security-octo-supply"
            exit 1
        fi
        
        # Enable Dependabot and Code Scanning
        echo "🛡️  Enabling security features..."
        gh api "repos/$FULL_REPO_NAME/vulnerability-alerts" -X PUT --silent 2>/dev/null
        gh api "repos/$FULL_REPO_NAME/automated-security-fixes" -X PUT --silent 2>/dev/null
        gh api "repos/$FULL_REPO_NAME/code-scanning/default-setup" -X PATCH \
            -f state=configured -f query_suite=default --silent 2>/dev/null
        echo "✅ Dependabot alerts, security updates, and Code Scanning enabled"
        
        clone_to_temp
        
        create_pr_from_resources \
            "feature-add-tos-download" \
            "pr-typescript" \
            "feat: Adds terms of services download" \
            "Demo: Preventing Vulnerabilities in TypeScript"
        
        create_pr_from_resources \
            "feature/supplier-notes" \
            "pr-php" \
            "feat: add supplier notes feature for internal communication" \
            "Demo: Preventing Vulnerabilities in PHP"
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

if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "codespace_and_issue" || "$WORKFLOW" == "issue_and_codespace" ]]; then
    echo ""
    echo "💡 You can access your codespace at: https://github.com/codespaces"
fi

echo ""
echo "✨ All done!"
