#!/bin/bash

# Consolidated script to create GitHub repos from various templates
# with different workflows based on the selected template

set -e  # Exit on any error

# Resolve path to resource files (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Create a PR branch from local resource files
# Usage: create_pr_from_resources <branch_name> <resource_subdir> <commit_msg> <pr_title>
create_pr_from_resources() {
    local branch_name="$1"
    local resource_subdir="$2"
    local commit_msg="$3"
    local pr_title="$4"
    local body_file="$SCRIPT_DIR/resources/security-octo-supply/$resource_subdir/pr-body.md"

    echo "📝 Creating PR: $pr_title..."
    git checkout -b "$branch_name" main
    cp -R "$SCRIPT_DIR/resources/security-octo-supply/$resource_subdir/" .
    rm -f pr-body.md  # Don't include the PR body file in the commit
    git add -A
    git commit -m "$commit_msg" --quiet
    git push -u origin "$branch_name" --quiet 2>/dev/null

    gh pr create \
        --repo "$FULL_REPO_NAME" \
        --head "$branch_name" \
        --base main \
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

# --- Template selection ---

echo ""
echo "📋 Available templates:"
echo "1. Game Repository (octobooth/gh-game)"
echo "   CLI games written in Go"
echo "   → Creates repo + new branch + codespace"
echo ""
echo "2. React Dashboard (octobooth/task-dashboard)"
echo "   Core React app for demoing code"
echo "   → Creates repo + codespace + issue assigned to Copilot"
echo ""
echo "3. Mona Gallery (octobooth/mona-gallery)"
echo "   Insecure version of Mona Gallery for security demos"
echo "   → Creates repo only"
echo ""
echo "4. Secure Code (github-samples/securing-your-code)"
echo "   Repo with a full set of labs and exercises about security"
echo "   → Creates repo only"
echo ""
echo "5. Security Supply Chain (octobooth/security-octo-supply)"
echo "   Security demo with TypeScript and PHP vulnerabilities"
echo "   → Creates repo + two demo PRs"
echo ""
echo "6. Tailspin Toys (octobooth/tailspin-toys)"
echo "   Game crowdfunding platform (Flask + Astro/Svelte)"
echo "   → Creates repo + issue assigned to Copilot + codespace"
echo ""

while true; do
    read -p "🎯 Select template (1-6): " choice
    case $choice in
        1)
            TEMPLATE_REPO="octobooth/gh-game"
            REPO_TYPE="game"
            WORKFLOW="branch_and_codespace"
            SUMMARY_EXTRA="Branch: new-game\n   Codespace: Created"
            break
            ;;
        2)
            TEMPLATE_REPO="octobooth/task-dashboard"
            REPO_TYPE="dashboard"
            WORKFLOW="codespace_and_issue"
            SUMMARY_EXTRA="Issue: Created and assigned to copilot\n   Codespace: Created"
            break
            ;;
        3)
            TEMPLATE_REPO="octobooth/mona-gallery"
            REPO_TYPE="gallery"
            WORKFLOW="repo_only"
            SUMMARY_EXTRA="Status: Repository ready for use"
            break
            ;;
        4)
            TEMPLATE_REPO="github-samples/securing-your-code"
            REPO_TYPE="secure-code"
            WORKFLOW="repo_only"
            SUMMARY_EXTRA="Status: Repository ready for use"
            break
            ;;
        5)
            TEMPLATE_REPO="octobooth/template-security-octo-supply"
            REPO_TYPE="security"
            WORKFLOW="security_prs"
            SUMMARY_EXTRA="Security features: Enabled\n   PRs: TypeScript + PHP demo PRs created"
            break
            ;;
        6)
            TEMPLATE_REPO="octobooth/template-tailspin-toys"
            REPO_TYPE="tailspin"
            WORKFLOW="issue_and_codespace"
            SUMMARY_EXTRA="Issue: Created and assigned to Copilot\n   Codespace: Created"
            break
            ;;
        *)
            echo "❌ Invalid choice. Please select 1, 2, 3, 4, 5, or 6."
            ;;
    esac
done

# --- Repository creation ---

# Generate 4 random alphanumeric characters for uniqueness
RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

# Create repository name
REPO_NAME="${CURRENT_USER}-${REPO_TYPE}-${RANDOM_SUFFIX}"
ORG_NAME="octobooth"
FULL_REPO_NAME="${ORG_NAME}/${REPO_NAME}"

echo ""
echo "📦 Creating repository: $FULL_REPO_NAME"
echo "🏗️  Using template: $TEMPLATE_REPO"

gh repo create "$FULL_REPO_NAME" \
    --template="$TEMPLATE_REPO" \
    --private \
    --description="$REPO_TYPE repository for $CURRENT_USER"

echo "✅ Repository created successfully: $FULL_REPO_NAME"

# Wait a moment for template to be fully processed
echo "⏳ Waiting for template to be fully processed..."
sleep 3

# --- Post-creation workflow ---

case $WORKFLOW in
    "branch_and_codespace")
        echo ""
        echo "🌿 Creating new branch and codespace..."
        
        clone_to_temp
        
        # Create new branch
        BRANCH_NAME="new-game"
        echo "🌿 Creating new branch: $BRANCH_NAME"
        
        # Ensure we're on the default branch
        DEFAULT_BRANCH=$(git branch -r | grep 'origin/HEAD' | cut -d'/' -f3 2>/dev/null || echo "main")
        echo "📍 Working from default branch: $DEFAULT_BRANCH"
        git checkout "$DEFAULT_BRANCH" 2>/dev/null || git checkout -b "$DEFAULT_BRANCH"
        git pull origin "$DEFAULT_BRANCH" 2>/dev/null || echo "Branch is up to date"
        
        # Create and push new branch
        git checkout -b "$BRANCH_NAME"
        git push -u origin "$BRANCH_NAME"
        echo "✅ Branch created and pushed: $BRANCH_NAME"
        
        # Start codespace on new branch
        echo "☁️  Starting codespace on branch $BRANCH_NAME..."
        gh codespace create \
            --repo "$FULL_REPO_NAME" \
            --branch "$BRANCH_NAME" \
            --machine "standardLinux32gb"
        echo "✅ Codespace created successfully!"
        ;;
        
    "codespace_and_issue")
        echo ""
        echo "📝 Creating issue and codespace..."
        
        # Create GitHub issue
        ISSUE_TITLE="Create Playwright tests to ensure functionality"
        ISSUE_BODY="We are missing any end to end tests. As such, we don't have an automated way to ensure everything is behaving correctly. Let's fix that by adding some Playwright tests.

## Requirements:

- Update the project to use Playwright
- Configure Playwright to use Chromium for testing
- Create Playwright tests for the core functionality of the website
- Ensure all tests pass
- Update package.json to add scripts to run the tests
- Create a new workflow to run the tests on PR or Merge into the main branch"
        
        gh issue create \
            --repo "$FULL_REPO_NAME" \
            --title "$ISSUE_TITLE" \
            --body "$ISSUE_BODY" \
            --assignee "@copilot"
        echo "✅ Issue created and assigned to copilot"
        
        # Start codespace on default branch
        echo "☁️  Starting codespace on default branch..."
        gh codespace create \
            --repo "$FULL_REPO_NAME" \
            --machine "basicLinux32gb"
        echo "✅ Codespace created successfully!"
        ;;
        
    "repo_only")
        echo ""
        echo "✅ Repository creation complete (no additional actions needed)"
        ;;
        
    "issue_and_codespace")
        echo ""
        echo "📝 Creating issue and codespace..."
        
        ISSUE_BODY_FILE="$SCRIPT_DIR/resources/$REPO_TYPE/issue-body.md"
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
        
        echo "☁️  Starting codespace..."
        gh codespace create \
            --repo "$FULL_REPO_NAME" \
            --machine "basicLinux32gb"
        echo "✅ Codespace created successfully!"
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
echo "   Template: $TEMPLATE_REPO"
echo "   User: $CURRENT_USER"
echo -e "   $SUMMARY_EXTRA"

if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "codespace_and_issue" || "$WORKFLOW" == "issue_and_codespace" ]]; then
    echo ""
    echo "💡 You can access your codespace at: https://github.com/codespaces"
fi

echo ""
echo "✨ All done!"
