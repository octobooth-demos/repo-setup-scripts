#!/bin/bash

# Consolidated script to create GitHub repos from various templates
# with different workflows based on the selected template

set -e  # Exit on any error

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

# Prompt user for template choice
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

while true; do
    read -p "🎯 Select template (1-4): " choice
    case $choice in
        1)
            TEMPLATE_REPO="octobooth/gh-game"
            REPO_TYPE="game"
            WORKFLOW="branch_and_codespace"
            break
            ;;
        2)
            TEMPLATE_REPO="octobooth/task-dashboard"
            REPO_TYPE="dashboard"
            WORKFLOW="codespace_and_issue"
            break
            ;;
        3)
            TEMPLATE_REPO="octobooth/mona-gallery"
            REPO_TYPE="gallery"
            WORKFLOW="repo_only"
            break
            ;;
        4)
            TEMPLATE_REPO="github-samples/securing-your-code"
            REPO_TYPE="secure-code"
            WORKFLOW="repo_only"
            break
            ;;
        *)
            echo "❌ Invalid choice. Please select 1, 2, 3, or 4."
            ;;
    esac
done

# Generate 4 random alphanumeric characters for uniqueness
RANDOM_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4)

# Create repository name
REPO_NAME="${CURRENT_USER}-${REPO_TYPE}-${RANDOM_SUFFIX}"
ORG_NAME="octobooth"
FULL_REPO_NAME="${ORG_NAME}/${REPO_NAME}"

echo ""
echo "📦 Creating repository: $FULL_REPO_NAME"
echo "🏗️  Using template: $TEMPLATE_REPO"

# Create repository from template
gh repo create "$FULL_REPO_NAME" \
    --template="$TEMPLATE_REPO" \
    --internal \
    --description="$REPO_TYPE repository for $CURRENT_USER"

if [ $? -eq 0 ]; then
    echo "✅ Repository created successfully: $FULL_REPO_NAME"
else
    echo "❌ Failed to create repository"
    exit 1
fi

# Wait a moment for template to be fully processed
echo "⏳ Waiting for template to be fully processed..."
sleep 3

# Execute workflow based on template choice
case $WORKFLOW in
    "branch_and_codespace")
        echo ""
        echo "🌿 Creating new branch and codespace..."
        
        # Clone repository locally for branch operations
        TEMP_DIR=$(mktemp -d)
        cd "$TEMP_DIR"
        gh repo clone "$FULL_REPO_NAME"
        cd "$REPO_NAME"
        
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
        
        if [ $? -eq 0 ]; then
            echo "✅ Branch created and pushed: $BRANCH_NAME"
        else
            echo "❌ Failed to create branch"
            exit 1
        fi
        
        # Start codespace on new branch
        echo "☁️  Starting codespace on branch $BRANCH_NAME..."
        gh codespace create \
            --repo "$FULL_REPO_NAME" \
            --branch "$BRANCH_NAME" \
            --machine "standardLinux32gb"
        
        # Clean up
        cd /
        rm -rf "$TEMP_DIR"
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
        
        if [ $? -eq 0 ]; then
            echo "✅ Issue created and assigned to copilot"
        else
            echo "⚠️  Issue creation failed, but continuing..."
        fi
        
        # Start codespace on default branch
        echo "☁️  Starting codespace on default branch..."
        gh codespace create \
            --repo "$FULL_REPO_NAME" \
            --machine "basicLinux32gb"
        ;;
        
    "repo_only")
        echo ""
        echo "✅ Repository creation complete (no additional actions needed)"
        ;;
esac

# Final status check and summary
if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "codespace_and_issue" ]]; then
    if [ $? -eq 0 ]; then
        echo "✅ Codespace created successfully!"
    else
        echo "❌ Failed to create codespace"
        echo "ℹ️  Repository was created successfully."
        echo "   You can manually create a codespace at: https://github.com/$FULL_REPO_NAME"
        exit 1
    fi
fi

echo ""
echo "🎉 Setup complete!"
echo ""
echo "📋 Summary:"
echo "   Repository: https://github.com/$FULL_REPO_NAME"
echo "   Template: $TEMPLATE_REPO"
echo "   User: $CURRENT_USER"

case $WORKFLOW in
    "branch_and_codespace")
        echo "   Branch: new-game"
        echo "   Codespace: Created"
        ;;
    "codespace_and_issue")
        echo "   Issue: Created and assigned to copilot"
        echo "   Codespace: Created"
        ;;
    "repo_only")
        echo "   Status: Repository ready for use"
        ;;
esac

if [[ "$WORKFLOW" == "branch_and_codespace" || "$WORKFLOW" == "codespace_and_issue" ]]; then
    echo ""
    echo "💡 You can access your codespace at: https://github.com/codespaces"
fi

echo ""
echo "✨ All done!"
